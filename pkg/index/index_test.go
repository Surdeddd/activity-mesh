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

func TestIngestDirIgnoresSyncthingConflictCopies(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	now := time.Now().UTC()
	at := func(ago time.Duration) string { return now.Add(-ago).Format("2006-01-02T15:04:05.000000Z") }
	shared := []string{
		buildLine(t, "01HRX0000000000000000000G1", at(2*time.Hour), "macbook", "cli", "scope:test", "note", "", "kept"),
		buildLine(t, "01HRX0000000000000000000G2", at(time.Hour), "macbook", "cli", "scope:test", "note", "", "kept too"),
	}
	live := writeJSONL(t, syncDir, "macbook", shared)
	copyOnly := buildLine(t, "01HRX0000000000000000000G3", at(time.Minute), "macbook", "cli", "scope:test", "note", "", "only in the copy")
	writeJSONL(t, syncDir, "macbook.sync-conflict-20261003-010203-ABCDEFG", append(append([]string{}, shared...), copyOnly))

	n, err := idx.IngestDir(syncDir)
	if err != nil || n != 2 {
		t.Fatalf("IngestDir: n=%d err=%v, want the 2 events of the live shard", n, err)
	}
	got, err := idx.Query(QueryFilter{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("index holds %d events, want 2 (the conflict copy must not add or move any)", len(got))
	}
	for _, e := range got {
		if e.Path != live {
			t.Errorf("event %s points at %s, want the live shard %s", e.ULID, e.Path, live)
		}
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

func deepNested(depth int) string {
	return strings.Repeat("[", depth) + strings.Repeat("]", depth)
}

func TestIngestSkipsOverNestedLine(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	ts := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05.000000Z")

	overNested := fmt.Sprintf(`{"v":1,"id":"01HRX00000000000000000PZ02","ts":%q,"host":"h1","agent":"a","kind":"note","scope":"s","summary":"nested","x":%s}`,
		ts, deepNested(1500))
	var probe map[string]any
	if err := json.Unmarshal([]byte(overNested), &probe); err != nil {
		t.Fatalf("precondition: Go's decoder must accept the line: %v", err)
	}
	path := writeJSONL(t, syncDir, "h1", []string{
		buildLine(t, "01HRX00000000000000000PZ01", ts, "h1", "a", "s", "note", "", "before nested"),
		overNested,
		buildLine(t, "01HRX00000000000000000PZ03", ts, "h1", "a", "s", "note", "", "after nested"),
	})

	n, err := idx.IngestJSONL(path)
	got, qerr := idx.Query(QueryFilter{Limit: 10})
	if qerr != nil {
		t.Fatal(qerr)
	}
	if err != nil || n != 2 || len(got) != 2 {
		t.Fatalf("an over-nested line must be skipped without failing the shard: ingest n=%d err=%v, indexed=%d (want 2, nil, 2)", n, err, len(got))
	}
	for _, e := range got {
		if e.ULID == "01HRX00000000000000000PZ02" {
			t.Errorf("over-nested event %s was indexed", e.ULID)
		}
	}
	if idx.SkippedLines() != 1 {
		t.Errorf("SkippedLines = %d, want 1", idx.SkippedLines())
	}
	if n2, err := idx.IngestJSONL(path); err != nil || n2 != 0 || idx.SkippedLines() != 1 {
		t.Errorf("second pass: n=%d err=%v skipped=%d, want 0, nil, 1 (cursor must move past the skipped line)", n2, err, idx.SkippedLines())
	}
}

func TestIngestDirIndexesLaterShardAfterOverNestedLine(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	ts := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05.000000Z")
	writeJSONL(t, syncDir, "alpha", []string{
		fmt.Sprintf(`{"v":1,"id":"01HRX00000000000000000PZA1","ts":%q,"host":"alpha","agent":"a","kind":"note","scope":"s","summary":"p","x":%s}`, ts, deepNested(1500)),
	})
	writeJSONL(t, syncDir, "beta", []string{
		buildLine(t, "01HRX00000000000000000PZB1", ts, "beta", "a", "s", "note", "", "healthy host event"),
	})

	_, err := idx.IngestDir(syncDir)
	got, qerr := idx.Query(QueryFilter{Host: "beta", Limit: 10})
	if qerr != nil {
		t.Fatal(qerr)
	}
	if err != nil || len(got) != 1 {
		t.Fatalf("host alpha's over-nested line must not hide host beta: IngestDir err=%v, beta indexed=%d (want nil, 1)", err, len(got))
	}
}

func indexWithBrokenAndVanishedShards(t *testing.T) (*Index, string) {
	t.Helper()
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	ts := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05.000000Z")
	gone := writeJSONL(t, syncDir, "aaa", []string{
		buildLine(t, "01HRX00000000000000000SW01", ts, "aaa", "a", "s", "note", "", "shard about to vanish"),
	})
	if _, err := idx.IngestDir(syncDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(syncDir, "events-bbb.jsonl"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeJSONL(t, syncDir, "ccc", []string{
		buildLine(t, "01HRX00000000000000000SW02", ts, "ccc", "a", "s", "note", "", "healthy host event"),
	})
	return idx, syncDir
}

func TestIngestDirContinuesAfterShardError(t *testing.T) {
	idx, syncDir := indexWithBrokenAndVanishedShards(t)

	n, err := idx.IngestDir(syncDir)
	if err == nil || !strings.Contains(err.Error(), "events-bbb.jsonl") {
		t.Errorf("IngestDir err = %v, want an error naming events-bbb.jsonl", err)
	}
	if n != 1 {
		t.Errorf("IngestDir indexed %d events, want 1 from the healthy shard", n)
	}
	healthy, qerr := idx.Query(QueryFilter{Host: "ccc", Limit: 10})
	if qerr != nil {
		t.Fatal(qerr)
	}
	if len(healthy) != 1 {
		t.Errorf("host ccc indexed %d events behind the failing shard, want 1", len(healthy))
	}
	vanished, qerr := idx.Query(QueryFilter{Host: "aaa", Limit: 10})
	if qerr != nil {
		t.Fatal(qerr)
	}
	if len(vanished) != 0 {
		t.Errorf("vanished shard still holds %d rows: the sweep must run after a failing shard", len(vanished))
	}
}

func TestIngestDirReportsShardAndSweepErrors(t *testing.T) {
	idx, syncDir := indexWithBrokenAndVanishedShards(t)
	if _, err := idx.db.Exec(`CREATE TRIGGER block_sweep BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'sweep blocked'); END`); err != nil {
		t.Fatal(err)
	}

	n, err := idx.IngestDir(syncDir)
	if err == nil {
		t.Fatal("IngestDir returned nil although a shard and the sweep both failed")
	}
	for _, want := range []string{"events-bbb.jsonl", "sweep: delete rows", "sweep blocked"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("IngestDir err = %q, want it to contain %q", err, want)
		}
	}
	if n != 1 {
		t.Errorf("IngestDir indexed %d events, want 1 from the healthy shard", n)
	}
}

func TestJSONDepth(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want int
	}{
		{"null", `null`, 0},
		{"scalar", `"s"`, 0},
		{"empty object", `{}`, 0},
		{"flat object", `{"a":1}`, 1},
		{"nested object", `{"a":{"b":1}}`, 2},
		{"array in object", `{"x":[[]]}`, 2},
		{"top-level arrays", `[[[]]]`, 2},
		{"deepest sibling wins", `{"a":1,"b":{"c":{"d":1}}}`, 3},
		{"512 nested arrays", `{"x":` + deepNested(512) + `}`, 512},
		{"513 nested arrays", `{"x":` + deepNested(513) + `}`, 513},
	}
	for _, c := range cases {
		var v any
		if err := json.Unmarshal([]byte(c.in), &v); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := JSONDepth(v); got != c.want {
			t.Errorf("%s: JSONDepth = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestIngestIndexesAtDepthLimitAndSkipsBeyondIt(t *testing.T) {
	idx, dir := setupIndex(t)
	syncDir := filepath.Join(dir, "sync")
	ts := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05.000000Z")
	line := func(id string, depth int) string {
		return fmt.Sprintf(`{"v":1,"id":%q,"ts":%q,"host":"h1","agent":"a","kind":"note","scope":"s","summary":"s","x":%s}`, id, ts, deepNested(depth))
	}
	path := writeJSONL(t, syncDir, "h1", []string{
		line("01HRX00000000000000000DL01", 512),
		line("01HRX00000000000000000DL02", 513),
	})

	n, err := idx.IngestJSONL(path)
	got, qerr := idx.Query(QueryFilter{Limit: 10})
	if qerr != nil {
		t.Fatal(qerr)
	}
	if err != nil || n != 1 || len(got) != 1 || got[0].ULID != "01HRX00000000000000000DL01" {
		t.Fatalf("512 levels must be indexed and 513 skipped: ingest n=%d err=%v, indexed=%d", n, err, len(got))
	}
	if idx.SkippedLines() != 1 {
		t.Errorf("SkippedLines = %d, want 1", idx.SkippedLines())
	}
}

func TestIngestUpsertFailureHandling(t *testing.T) {
	const failID = "01HRX00000000000000000TG02"
	cases := []struct {
		name        string
		abortMsg    string
		wantErr     bool
		wantIndexed int
		wantSkipped uint64
	}{
		{"malformed JSON is skipped", "malformed JSON", false, 2, 1},
		{"any other failure aborts the pass", "boom", true, 0, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			idx, dir := setupIndex(t)
			syncDir := filepath.Join(dir, "sync")
			ts := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05.000000Z")
			trigger := fmt.Sprintf(`CREATE TRIGGER reject_one BEFORE INSERT ON events WHEN new.ulid = '%s' BEGIN SELECT RAISE(ABORT, '%s'); END`, failID, c.abortMsg)
			if _, err := idx.db.Exec(trigger); err != nil {
				t.Fatal(err)
			}
			path := writeJSONL(t, syncDir, "h1", []string{
				buildLine(t, "01HRX00000000000000000TG01", ts, "h1", "a", "s", "note", "", "first"),
				buildLine(t, failID, ts, "h1", "a", "s", "note", "", "rejected"),
				buildLine(t, "01HRX00000000000000000TG03", ts, "h1", "a", "s", "note", "", "third"),
			})

			_, err := idx.IngestJSONL(path)
			got, qerr := idx.Query(QueryFilter{Limit: 10})
			if qerr != nil {
				t.Fatal(qerr)
			}
			if (err != nil) != c.wantErr {
				t.Fatalf("IngestJSONL err = %v, wantErr %v", err, c.wantErr)
			}
			if c.wantErr && !strings.Contains(err.Error(), "upsert ulid="+failID) {
				t.Errorf("IngestJSONL err = %q, want an upsert ulid=%s error", err, failID)
			}
			if len(got) != c.wantIndexed {
				t.Errorf("indexed %d events, want %d", len(got), c.wantIndexed)
			}
			if idx.SkippedLines() != c.wantSkipped {
				t.Errorf("SkippedLines = %d, want %d", idx.SkippedLines(), c.wantSkipped)
			}
		})
	}
}

func TestSQLiteRejectsOverDeepJSONWithKnownMessage(t *testing.T) {
	idx, _ := setupIndex(t)
	var out string
	if err := idx.db.QueryRow(`SELECT json(?)`, deepNested(1000)).Scan(&out); err != nil {
		t.Fatalf("json() must accept 1000 levels: %v", err)
	}
	err := idx.db.QueryRow(`SELECT json(?)`, deepNested(1001)).Scan(&out)
	if err == nil || !strings.Contains(err.Error(), "malformed JSON") {
		t.Fatalf("json() on 1001 levels: err = %v, want one containing \"malformed JSON\"", err)
	}
}
