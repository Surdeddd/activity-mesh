package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Surdeddd/activity-mesh/pkg/index"
)

func shardLine(i int, ts time.Time, summary string) string {
	return fmt.Sprintf(`{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G%04d","ts":%q,"host":"conv-h","agent":"t","kind":"note","scope":"s","summary":%q}`,
		i, ts.UTC().Format("2006-01-02T15:04:05.000000Z"), summary)
}

func writeLines(t *testing.T, path string, lines []string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func openIdx(t *testing.T) *index.Index {
	t.Helper()
	idx, err := index.NewIndex(filepath.Join(t.TempDir(), "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = idx.Close() })
	return idx
}

func indexState(t *testing.T, idx *index.Index) map[string]string {
	t.Helper()
	evs, err := idx.Query(index.QueryFilter{Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, e := range evs {
		s, _ := e.Payload["summary"].(string)
		out[e.ULID] = fmt.Sprintf("%s@%d", s, e.Offset)
	}
	return out
}

func TestRedactShardPurgesIndexEndToEnd(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "store")
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	shard := filepath.Join(dir, "events-conv-h.jsonl")
	secret := "ghp_" + strings.Repeat("Z", 36)
	now := time.Now()
	writeLines(t, shard, []string{
		shardLine(0, now, "clean"),
		shardLine(1, now, "leaked "+secret),
	})

	idx := openIdx(t)
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if hits, _ := idx.Search(secret, time.Time{}, 10); len(hits) != 1 {
		t.Fatalf("precondition: want the secret indexed, got %d hits", len(hits))
	}

	res, err := redactShard(shard, store, "conv-h", false)
	if err != nil {
		t.Fatal(err)
	}
	if res.changed != 1 {
		t.Fatalf("redactShard changed=%d, want 1", res.changed)
	}
	raw, _ := os.ReadFile(shard)
	if strings.Contains(string(raw), secret) {
		t.Fatal("secret survived in the shard file")
	}

	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if hits, _ := idx.Search(secret, time.Time{}, 10); len(hits) != 0 {
		t.Fatalf("secret still searchable after redact-shard + re-ingest: %+v", hits)
	}
	for ulid, s := range indexState(t, idx) {
		if strings.Contains(s, secret) {
			t.Fatalf("secret survived in indexed payload for %s", ulid)
		}
	}
	fresh := openIdx(t)
	if _, err := fresh.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if got, want := indexState(t, idx), indexState(t, fresh); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("post-redact index diverged from fresh:\n old=%v\nfresh=%v", got, want)
	}
}

func TestCompactShardIndexConvergesEndToEnd(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "store")
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	shard := filepath.Join(dir, "events-conv-h.jsonl")
	old := time.Now().Add(-120 * 24 * time.Hour)
	now := time.Now()
	writeLines(t, shard, []string{
		shardLine(0, old, "ancient-0"),
		shardLine(1, old, "ancient-1"),
		shardLine(2, now, "live-2"),
		shardLine(3, now, "live-3"),
	})

	idx := openIdx(t)
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if len(indexState(t, idx)) != 4 {
		t.Fatal("precondition: 4 events indexed")
	}

	res, err := compactShard(compactOptions{
		shardPath:  shard,
		archiveDir: filepath.Join(dir, "archive"),
		host:       "conv-h",
		storeDir:   store,
		cutoff:     time.Now().Add(-90 * 24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.archived != 2 || res.kept != 2 {
		t.Fatalf("compact archived=%d kept=%d, want 2/2", res.archived, res.kept)
	}

	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	got := indexState(t, idx)
	if len(got) != 2 {
		t.Fatalf("archived events must leave the index, got %v", got)
	}
	if hits, _ := idx.Search("ancient-0", time.Time{}, 10); len(hits) != 0 {
		t.Fatalf("archived event still searchable: %+v", hits)
	}

	fresh := openIdx(t)
	if _, err := fresh.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if want := indexState(t, fresh); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("post-compact index diverged from fresh:\n old=%v\nfresh=%v", got, want)
	}
}
