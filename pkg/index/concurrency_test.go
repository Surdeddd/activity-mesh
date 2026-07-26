package index

import (
	"path/filepath"
	"testing"
	"time"
)

// Reads must not queue behind a full rescan. Sharing the writer's single
// connection made /recent and /search block for the whole ingest — well past
// the daemon's 15s ReadTimeout on a large shard.
//
// The assertion is relative, not a wall-clock target: the query must return
// while the ingest is demonstrably still running, and in a small fraction of
// the time that ingest takes.
func TestQueryDoesNotBlockBehindIngest(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a multi-thousand-event shard")
	}
	idx, dir := newTempIndex(t)
	shard := filepath.Join(dir, "events-h1.jsonl")

	// Big enough that the ingest transaction is still open when the query runs,
	// small enough that CI's `-race` pass stays quick.
	const n = 5000
	first := make([]string, 0, n)
	rewritten := make([]string, 0, n)
	for i := 0; i < n; i++ {
		first = append(first, evLine(i, "bulk event body for latency measurement"))
		// Different bytes so the cursor's prefix hash mismatches and the second
		// pass is a genuine full rescan rather than an instant no-op.
		rewritten = append(rewritten, evLine(i, "bulk event body for latency measurement (redacted)"))
	}
	writeShardFile(t, shard, first)
	if _, err := idx.IngestJSONL(shard); err != nil {
		t.Fatal(err)
	}
	writeShardFile(t, shard, rewritten)

	done := make(chan time.Duration, 1)
	go func() {
		start := time.Now()
		if _, err := idx.IngestJSONL(shard); err != nil {
			t.Error(err)
		}
		done <- time.Since(start)
	}()
	time.Sleep(100 * time.Millisecond) // let the ingest transaction open

	start := time.Now()
	if _, err := idx.Query(QueryFilter{Limit: 10}); err != nil {
		t.Fatalf("query during ingest: %v", err)
	}
	queryLatency := time.Since(start)

	var ingestStillRunning bool
	select {
	case ingest := <-done:
		if queryLatency > ingest/4 {
			t.Errorf("query took %s of the %s ingest — reads are queued behind the writer", queryLatency, ingest)
		}
		return
	default:
		ingestStillRunning = true
	}
	ingest := <-done
	if !ingestStillRunning {
		t.Skip("ingest finished before the query started — inconclusive")
	}
	if queryLatency > ingest/4 {
		t.Errorf("query took %s of the %s ingest — reads are queued behind the writer", queryLatency, ingest)
	}
	t.Logf("query %s vs ingest %s", queryLatency, ingest)
}
