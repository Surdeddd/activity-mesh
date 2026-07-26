package index

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// `compact --keep <short>` can move every event out of a shard. The index must
// follow it to zero instead of serving rows whose only copy now lives in the
// archive.
func TestIngestShardDrainedToEmptyDropsRows(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(1, "archive me")})

	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if st, _ := idx.Stats(); st.TotalEvents != 1 {
		t.Fatalf("setup: TotalEvents = %d, want 1", st.TotalEvents)
	}

	if err := os.WriteFile(shard, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}

	st, err := idx.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if st.TotalEvents != 0 {
		t.Errorf("TotalEvents = %d, want 0 — index still serves archived events", st.TotalEvents)
	}
	hits, err := idx.Search("archive", time.Time{}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 0 {
		t.Errorf("FTS returned %d hits for a drained shard, want 0", len(hits))
	}
}

// The recovery runbook says: delete index.db and let the daemon rebuild. The
// cursor sidecar must not survive that and skip the whole file.
func TestCursorsResetWhenIndexDBIsDeleted(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "index.db")
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(1, "a"), evLine(2, "b"), evLine(3, "c")})

	idx, err := NewIndex(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if n, err := idx.IngestJSONL(shard); err != nil || n != 3 {
		t.Fatalf("initial ingest: n=%d err=%v", n, err)
	}
	if err := idx.Close(); err != nil {
		t.Fatal(err)
	}

	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(dbPath + suffix)
	}
	if _, err := os.Stat(filepath.Join(dir, "cursors.json")); err != nil {
		t.Fatalf("precondition: cursors.json should still exist: %v", err)
	}

	rebuilt, err := NewIndex(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer rebuilt.Close()
	if _, err := rebuilt.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	st, err := rebuilt.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if st.TotalEvents != 3 {
		t.Errorf("TotalEvents = %d, want 3 — stale cursors skipped the rebuild", st.TotalEvents)
	}
}

// Losing events_fts (manual repair, partial restore) must not turn /search into
// a silent zero-hit endpoint.
func TestFTSRebuiltWhenEmptyButEventsExist(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "index.db")
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{evLine(1, "alpha beta")})

	idx, err := NewIndex(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	if _, err := idx.db.Exec(`DROP TABLE events_fts`); err != nil {
		t.Fatal(err)
	}
	if err := idx.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewIndex(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	hits, err := reopened.Search("alpha", time.Time{}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 {
		t.Errorf("Search after FTS loss returned %d hits, want 1", len(hits))
	}
}

// Load-bearing invariant: archives are never indexed. Guards the glob against a
// future switch to a recursive walk.
func TestIngestDirNeverIndexesArchives(t *testing.T) {
	idx, dir := newTempIndex(t)
	writeShardFile(t, filepath.Join(dir, "events-h1.jsonl"), []string{evLine(1, "live event")})

	archiveDir := filepath.Join(dir, "archive")
	if err := os.MkdirAll(archiveDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Uncompressed on purpose: a naive recursive walk would happily ingest it.
	writeShardFile(t, filepath.Join(archiveDir, "events-h1-2026-01.jsonl"), []string{evLine(99, "archived event")})

	if _, err := idx.IngestDir(dir); err != nil {
		t.Fatal(err)
	}
	for _, e := range mustQuery(t, idx) {
		if s, _ := e.Payload["summary"].(string); s == "archived event" {
			t.Fatalf("archived event %s made it into the index", e.ULID)
		}
	}
	hits, err := idx.Search("archived", time.Time{}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 0 {
		t.Errorf("FTS matched %d archived events, want 0", len(hits))
	}
}

// A line whose ts no layout accepts used to be indexed at epoch 0, where every
// time-windowed query silently missed it.
func TestIngestSkipsUnparseableTimestamps(t *testing.T) {
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")
	writeShardFile(t, shard, []string{
		evLine(1, "good"),
		`{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69GBAD1","ts":"2026-07-26 10:00:00","host":"h1","agent":"t","kind":"note","scope":"s","summary":"bad ts"}`,
	})

	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	for _, e := range mustQuery(t, idx) {
		if e.TSUnix == 0 {
			t.Errorf("event %s indexed at epoch 0 (ts=%q)", e.ULID, e.TS)
		}
	}
	if idx.SkippedLines() != 1 {
		t.Errorf("SkippedLines = %d, want 1", idx.SkippedLines())
	}
}

func mustQuery(t *testing.T, idx *Index) []Event {
	t.Helper()
	got, err := idx.Query(QueryFilter{Limit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	return got
}
