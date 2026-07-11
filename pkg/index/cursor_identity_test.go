package index

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
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

func newTempIndex(t *testing.T) (*Index, string) {
	t.Helper()
	dir := t.TempDir()
	idx, err := NewIndex(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = idx.Close() })
	return idx, dir
}

func summaries(t *testing.T, idx *Index) map[string]string {
	t.Helper()
	got, err := idx.Query(QueryFilter{Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, e := range got {
		s, _ := e.Payload["summary"].(string)
		out[e.ULID] = s
	}
	return out
}

func TestCursorResetOnRewrite(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")

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

	var kept []string
	for i := 1; i < 6; i++ {
		s := "b"
		if i != 1 {
			s = fmt.Sprintf("tail-%d", i)
		}
		kept = append(kept, evLine(i, s))
	}
	writeShardFile(t, shard, kept)

	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	got := summaries(t, idx)
	for i := 2; i < 6; i++ {
		if got[fmt.Sprintf("01ARZ3NDEKTSV4RRFFQ69G%04d", i)] != fmt.Sprintf("tail-%d", i) {
			t.Fatalf("tail event %d skipped after rewrite (stale cursor); got %v", i, got)
		}
	}
	if _, ok := got["01ARZ3NDEKTSV4RRFFQ69G0000"]; ok {
		t.Fatal("event dropped from shard must be reconciled out of the index")
	}
}

func TestRewriteSameHeadNotSmaller(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")
	secret := "hunter2-super-secret"

	writeShardFile(t, shard, []string{evLine(0, "clean head"), evLine(1, "leak "+secret), evLine(2, "tail")})
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	padded := "REDACTED-" + strings.Repeat("x", len(secret)-4)
	writeShardFile(t, shard, []string{evLine(0, "clean head"), evLine(1, "leak "+padded), evLine(2, "tail")})
	fi1, _ := os.Stat(shard)
	if fi1.Size() == 0 {
		t.Fatal("setup broken")
	}
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	got := summaries(t, idx)
	if strings.Contains(got["01ARZ3NDEKTSV4RRFFQ69G0001"], secret) {
		t.Fatalf("stale payload survived a same-head not-smaller rewrite: %v", got)
	}
	hits, err := idx.Search(secret, time.Time{}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 0 {
		t.Fatalf("FTS still finds the pre-rewrite secret: %+v", hits)
	}
}

func TestRedactedPayloadPurgedFromPayloadAndFTS(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")
	secret := "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

	writeShardFile(t, shard, []string{evLine(0, "token is "+secret)})
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if hits, _ := idx.Search("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", time.Time{}, 10); len(hits) != 1 {
		t.Fatalf("precondition: secret must be searchable before redaction, got %d hits", len(hits))
	}

	writeShardFile(t, shard, []string{evLine(0, "token is [REDACTED:github_token:40]")})
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	if hits, _ := idx.Search("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", time.Time{}, 10); len(hits) != 0 {
		t.Fatalf("secret still searchable after redact rewrite: %+v", hits)
	}
	got := summaries(t, idx)
	if strings.Contains(got["01ARZ3NDEKTSV4RRFFQ69G0000"], secret) {
		t.Fatalf("secret survived in payload: %v", got)
	}
	if hits, _ := idx.Search("REDACTED", time.Time{}, 10); len(hits) != 1 {
		t.Fatal("updated payload must be searchable by its new content")
	}
}

func TestIngestCountsOnlyRealChanges(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(0, "a"), evLine(1, "b"), evLine(2, "c")})
	if n, _ := idx.IngestJSONL(shard); n != 3 {
		t.Fatalf("want 3 inserts, got %d", n)
	}
	if n, _ := idx.IngestJSONL(shard); n != 0 {
		t.Fatalf("unchanged file re-ingest must report 0, got %d", n)
	}
	f, _ := os.OpenFile(shard, os.O_APPEND|os.O_WRONLY, 0o644)
	fmt.Fprintln(f, evLine(3, "d"))
	f.Close()
	if n, _ := idx.IngestJSONL(shard); n != 1 {
		t.Fatalf("append of one event must report 1, got %d", n)
	}
	if err := os.Remove(filepath.Join(dir, "cursors.json")); err != nil {
		t.Fatal(err)
	}
	if n, _ := idx.IngestJSONL(shard); n != 0 {
		t.Fatalf("full rescan of identical content must report 0 changes, got %d", n)
	}
}

func TestConvergenceExistingVsFreshIndex(t *testing.T) {
	idxOld, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")

	writeShardFile(t, shard, []string{evLine(0, "old-0"), evLine(1, "old-1"), evLine(2, "keep-2"), evLine(3, "secret-xyzzy-3")})
	if _, err := idxOld.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	writeShardFile(t, shard, []string{evLine(2, "keep-2"), evLine(3, "scrubbed-3"), evLine(4, "new-4")})
	if _, err := idxOld.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	freshDir := t.TempDir()
	idxFresh, err := NewIndex(filepath.Join(freshDir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer idxFresh.Close()
	if _, err := idxFresh.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	oldEvents := summaries(t, idxOld)
	freshEvents := summaries(t, idxFresh)
	if len(oldEvents) != len(freshEvents) {
		t.Fatalf("event count diverged: old=%d fresh=%d", len(oldEvents), len(freshEvents))
	}
	var keys []string
	for k := range oldEvents {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if oldEvents[k] != freshEvents[k] {
			t.Fatalf("payload diverged for %s: old=%q fresh=%q", k, oldEvents[k], freshEvents[k])
		}
	}
	oldOffsets, _ := idxOld.Query(QueryFilter{Limit: 100})
	freshOffsets, _ := idxFresh.Query(QueryFilter{Limit: 100})
	off := func(evs []Event) map[string]int64 {
		m := map[string]int64{}
		for _, e := range evs {
			m[e.ULID] = e.Offset
		}
		return m
	}
	om, fm := off(oldOffsets), off(freshOffsets)
	for k, v := range fm {
		if om[k] != v {
			t.Fatalf("raw_byte_offset stale for %s: old=%d fresh=%d", k, om[k], v)
		}
	}
}

func TestIngestDirRemovesVanishedShardRows(t *testing.T) {
	idx, dir := newTempIndex(t)
	sync := filepath.Join(dir, "sync")
	if err := os.MkdirAll(sync, 0o755); err != nil {
		t.Fatal(err)
	}
	a := filepath.Join(sync, "events-a.jsonl")
	b := filepath.Join(sync, "events-b.jsonl")
	writeShardFile(t, a, []string{evLine(0, "from-a")})
	writeShardFile(t, b, []string{evLine(1, "from-b")})
	if _, err := idx.IngestDir(sync); err != nil {
		t.Fatal(err)
	}
	if got := summaries(t, idx); len(got) != 2 {
		t.Fatalf("want 2 events, got %v", got)
	}
	if err := os.Remove(b); err != nil {
		t.Fatal(err)
	}
	if _, err := idx.IngestDir(sync); err != nil {
		t.Fatal(err)
	}
	got := summaries(t, idx)
	if len(got) != 1 {
		t.Fatalf("rows of a vanished shard must be removed, got %v", got)
	}
	if hits, _ := idx.Search("from-b", time.Time{}, 10); len(hits) != 0 {
		t.Fatalf("FTS entry of vanished shard survived: %+v", hits)
	}
}

func TestSearchMultiWord(t *testing.T) {
	idx, dir := newTempIndex(t)
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
