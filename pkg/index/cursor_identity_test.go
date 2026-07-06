// Cursor-identity regressions: a shard rewritten to a size that is still
// LARGER than the stored cursor (compaction removing less than the unread
// backlog, or a sync replace) must trigger a full rescan — the old
// size-only check kept a stale mid-file cursor and silently skipped the
// unread tail forever.


package index

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeShardFile(t *testing.T, path string, lines []string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func evLine(i int, summary string) string {
	ts := time.Now().UTC().Format("2006-01-02T15:04:05.000000Z")
	return fmt.Sprintf(`{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G%04d","ts":%q,"host":"h1","agent":"t","kind":"note","scope":"s","summary":%q}`, i, ts, summary)
}

func TestCursorResetOnHeadChange(t *testing.T) {
	dir := t.TempDir()
	idx, err := NewIndex(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer idx.Close()
	shard := filepath.Join(dir, "events-h1.jsonl")

	// 1. ingest only the first 2 of 6 events (simulate a lagging cursor by
	//    writing 2, ingesting, then appending 4 more WITHOUT ingesting).
	writeShardFile(t, shard, []string{evLine(0, "a"), evLine(1, "b")})
	if n, err := idx.IngestJSONL(shard); err != nil || n != 2 {
		t.Fatalf("first ingest: n=%d err=%v", n, err)
	}
	f, err := os.OpenFile(shard, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	for i := 2; i < 6; i++ {
		fmt.Fprintln(f, evLine(i, fmt.Sprintf("tail-%d", i)))
	}
	f.Close()

	// 2. "compact": drop the first line, keep the rest — the file is still
	//    larger than the stored cursor (which points after line 2).
	var kept []string
	for i := 1; i < 6; i++ {
		kept = append(kept, evLine(i, map[bool]string{true: "b", false: fmt.Sprintf("tail-%d", i)}[i == 1]))
	}
	writeShardFile(t, shard, kept)

	// 3. re-ingest: head hash changed → full rescan → tail events land.
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	got, err := idx.Query(QueryFilter{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	bySummary := map[string]bool{}
	for _, e := range got {
		if s, ok := e.Payload["summary"].(string); ok {
			bySummary[s] = true
		}
	}
	for i := 2; i < 6; i++ {
		if !bySummary[fmt.Sprintf("tail-%d", i)] {
			t.Fatalf("tail event %d skipped after rewrite (stale cursor); got %v", i, bySummary)
		}
	}
}

// TestIngestCountsOnlyRealInserts — INSERT OR IGNORE dedup hits must not
// inflate the ingested counter after a cursor reset.
func TestIngestCountsOnlyRealInserts(t *testing.T) {
	dir := t.TempDir()
	idx, err := NewIndex(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer idx.Close()
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(0, "a"), evLine(1, "b"), evLine(2, "c")})
	if n, _ := idx.IngestJSONL(shard); n != 3 {
		t.Fatalf("want 3 inserts, got %d", n)
	}
	// force rescan by rewriting the head with identical content order but a
	// changed first byte (different first line → head hash mismatch)
	writeShardFile(t, shard, []string{evLine(1, "b"), evLine(0, "a"), evLine(2, "c")})
	n, err := idx.IngestJSONL(shard)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("rescan of known events must report 0 new inserts, got %d", n)
	}
}

// TestSearchMultiWord — multi-word queries must not require adjacency.
func TestSearchMultiWord(t *testing.T) {
	dir := t.TempDir()
	idx, err := NewIndex(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer idx.Close()
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(0, "deployed the billing proxy to production")})
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	hits, err := idx.Search("billing production", time.Time{}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 {
		t.Fatalf("multi-word search: want 1 hit, got %d", len(hits))
	}
}
