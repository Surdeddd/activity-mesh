// These tests exercise FTS5 SQL and need the sqlite_fts5 driver tag
// (CGO_ENABLED=1). Run via `make test`; plain `go test ./...` skips them.

//go:build sqlite_fts5

package index

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// helper: build a minimal valid event JSONL line.
func buildLine(t *testing.T, ulid, ts, host, agent, scope, kind, prio, summary string) string {
	t.Helper()
	m := map[string]any{
		"v": 1, "id": ulid, "ts": ts, "host": host,
		"agent": agent, "scope": scope, "kind": kind, "summary": summary,
	}
	if prio != "" {
		m["priority"] = prio
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

// writeJSONL writes lines (joined by \n) into syncDir/events-<host>.jsonl.
func writeJSONL(t *testing.T, syncDir, host string, lines []string) string {
	t.Helper()
	if err := os.MkdirAll(syncDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(syncDir, "events-"+host+".jsonl")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, l := range lines {
		if _, err := f.WriteString(l + "\n"); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func setupIndex(t *testing.T) (*Index, string) {
	t.Helper()
	dir := t.TempDir()
	idx, err := NewIndex(filepath.Join(dir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = idx.Close() })
	return idx, dir
}

func TestSchemaCreated(t *testing.T) {
	idx, _ := setupIndex(t)
	row := idx.db.QueryRow(`SELECT name FROM sqlite_master WHERE name = 'events_fts'`)
	var name string
	if err := row.Scan(&name); err != nil {
		t.Fatalf("FTS5 virtual table missing: %v", err)
	}
	if name != "events_fts" {
		t.Errorf("expected events_fts, got %s", name)
	}
}

func TestIngestAndQuery(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	now := time.Now().UTC()
	lines := []string{
		buildLine(t, "01HRX0000000000000000000A1", now.Add(-3*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "claude-mac", "project:openclaw", "decision", "P1", "fixed billing-proxy oauth"),
		buildLine(t, "01HRX0000000000000000000A2", now.Add(-2*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "hermes", "project:hermes", "config", "", "soul update"),
		buildLine(t, "01HRX0000000000000000000A3", now.Add(-1*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macmini", "claude-mac", "project:openclaw", "task", "P2", "rebuilt index for verifier"),
	}
	writeJSONL(t, syncDir, "macbook", lines[:2])
	writeJSONL(t, syncDir, "macmini", lines[2:])

	n, err := idx.IngestDir(syncDir)
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	if n != 3 {
		t.Errorf("expected 3 events, got %d", n)
	}

	all, err := idx.Query(QueryFilter{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Errorf("expected 3 events, got %d", len(all))
	}

	openclaw, err := idx.Query(QueryFilter{Scope: "project:openclaw", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(openclaw) != 2 {
		t.Errorf("expected 2 openclaw, got %d", len(openclaw))
	}

	hermesAgent, err := idx.Query(QueryFilter{Agent: "hermes", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(hermesAgent) != 1 {
		t.Errorf("expected 1 hermes agent event, got %d", len(hermesAgent))
	}
}

func TestIngestIncremental(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	now := time.Now().UTC()
	first := []string{
		buildLine(t, "01HRX0000000000000000000B1", now.Add(-2*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "first batch a"),
		buildLine(t, "01HRX0000000000000000000B2", now.Add(-1*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "first batch b"),
	}
	writeJSONL(t, syncDir, "macbook", first)
	if n, err := idx.IngestDir(syncDir); err != nil || n != 2 {
		t.Fatalf("first ingest: n=%d err=%v", n, err)
	}

	// Append more lines, re-ingest — only new lines should be added.
	more := []string{
		buildLine(t, "01HRX0000000000000000000B3", now.Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "second batch c"),
	}
	writeJSONL(t, syncDir, "macbook", more)
	n2, err := idx.IngestDir(syncDir)
	if err != nil {
		t.Fatal(err)
	}
	if n2 != 1 {
		t.Errorf("expected 1 incremental event, got %d", n2)
	}

	stats, err := idx.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if stats.TotalEvents != 3 {
		t.Errorf("expected 3 total, got %d", stats.TotalEvents)
	}
}

func TestSearchFTS5(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	now := time.Now().UTC()
	lines := []string{
		buildLine(t, "01HRX0000000000000000000C1", now.Add(-3*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "rebuilt the billing proxy after oauth refresh"),
		buildLine(t, "01HRX0000000000000000000C2", now.Add(-2*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "drafted plan for openclaw verifier"),
		buildLine(t, "01HRX0000000000000000000C3", now.Add(-1*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "scope:test", "note", "", "sent voice message to maxim"),
	}
	writeJSONL(t, syncDir, "macbook", lines)
	if _, err := idx.IngestDir(syncDir); err != nil {
		t.Fatal(err)
	}

	hits, err := idx.Search("billing", time.Time{}, 10)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(hits) != 1 {
		t.Fatalf("expected 1 billing hit, got %d", len(hits))
	}
	got, _ := hits[0].Payload["summary"].(string)
	if !strings.Contains(got, "billing") {
		t.Errorf("expected billing in summary, got %q", got)
	}
}

func TestAggregate(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	now := time.Now().UTC()
	lines := []string{
		buildLine(t, "01HRX0000000000000000000D1", now.Add(-3*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "project:openclaw", "decision", "", "x"),
		buildLine(t, "01HRX0000000000000000000D2", now.Add(-2*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "project:openclaw", "decision", "", "y"),
		buildLine(t, "01HRX0000000000000000000D3", now.Add(-1*time.Hour).Format("2006-01-02T15:04:05.000000Z"), "macbook", "cli", "project:hermes", "config", "", "z"),
	}
	writeJSONL(t, syncDir, "macbook", lines)
	if _, err := idx.IngestDir(syncDir); err != nil {
		t.Fatal(err)
	}

	agg, err := idx.Aggregate("scope", "24h")
	if err != nil {
		t.Fatal(err)
	}
	if agg["project:openclaw"] != 2 || agg["project:hermes"] != 1 {
		t.Errorf("aggregate wrong: %+v", agg)
	}
}

func TestQueryLatencyP95_10K(t *testing.T) {
	if testing.Short() {
		t.Skip("skip 10K perf test in -short")
	}
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")

	// Generate 10K events spread across the last 24h to exercise the index.
	const N = 10_000
	base := time.Now().UTC().Add(-24 * time.Hour)
	scopes := []string{"project:openclaw", "project:hermes", "project:billing", "infra:macbook", "scope:test"}
	agents := []string{"claude-mac", "hermes", "cli", "viktor"}
	lines := make([]string, 0, N)
	for i := 0; i < N; i++ {
		ts := base.Add(time.Duration(i) * time.Second).Format("2006-01-02T15:04:05.000000Z")
		ulid := fmt.Sprintf("01HRX0000000000000000%06d", i)
		lines = append(lines, buildLine(t, ulid, ts, "macbook", agents[i%len(agents)], scopes[i%len(scopes)], "note", "", fmt.Sprintf("synthetic event %d", i)))
		if (i+1)%2000 == 0 {
			writeJSONL(t, syncDir, "macbook", lines)
			lines = lines[:0]
		}
	}
	if len(lines) > 0 {
		writeJSONL(t, syncDir, "macbook", lines)
	}

	t0 := time.Now()
	if _, err := idx.IngestDir(syncDir); err != nil {
		t.Fatal(err)
	}
	t.Logf("ingest 10K events in %s", time.Since(t0))

	stats, err := idx.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if stats.TotalEvents != N {
		t.Errorf("expected %d total, got %d", N, stats.TotalEvents)
	}

	const trials = 100
	times := make([]time.Duration, 0, trials)
	for k := 0; k < trials; k++ {
		t1 := time.Now()
		_, err := idx.Query(QueryFilter{Scope: scopes[k%len(scopes)], Limit: 50})
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		times = append(times, time.Since(t1))
	}
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	p95 := times[int(float64(trials)*0.95)]
	p99 := times[int(float64(trials)*0.99)]
	t.Logf("p95 query latency = %s, p99 = %s, max = %s", p95, p99, times[trials-1])

	if p95 > 50*time.Millisecond {
		t.Errorf("p95 %s exceeded 50ms target", p95)
	}
}
