package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/redact"
)

func pushBody(over map[string]any) string {
	body := map[string]any{
		"v": 1, "id": "01HRX0000000000000000000T1", "ts": tsNow(0),
		"host": "test-host", "agent": "pusher", "kind": "note", "scope": "s", "summary": "x",
	}
	for k, v := range over {
		body[k] = v
	}
	b, _ := json.Marshal(body)
	return string(b)
}

func doPush(t *testing.T, d *daemon, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(body))
	w := httptest.NewRecorder()
	d.handlePush(w, req)
	return w
}

func rawShardLines(t *testing.T, d *daemon) []string {
	t.Helper()
	buf, err := os.ReadFile(filepath.Join(d.syncDir, "events-test-host.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(buf), "\n"), "\n")
}

func recentCount(t *testing.T, d *daemon) int {
	t.Helper()
	w := httptest.NewRecorder()
	d.handleRecent(w, httptest.NewRequest(http.MethodGet, "/recent?host=test-host&limit=100", nil))
	var resp struct {
		Count int `json:"count"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("recent: %v (%s)", err, w.Body.String())
	}
	return resp.Count
}

func dbURLAtCapBoundary() (summary, password string) {
	password = "S3cr3tPassw0rd"
	head := "postgres://admin:" + password
	pad := strings.Repeat("word ", 200)[:event.MaxSummaryRunes-2-len(head)] + " "
	return pad + head + "@db.internal:5432/app", password
}

func TestHandlePushRejectsTraversalHost(t *testing.T) {
	d, dir := newTestDaemon(t)
	for _, host := range []string{"../../evil", "a/b", "..", ".hidden/../..", "x\\y", ""} {
		w := doPush(t, d, pushBody(map[string]any{"host": host}))
		if w.Code != http.StatusBadRequest {
			t.Errorf("host %q: expected 400, got %d", host, w.Code)
		}
	}
	entries, _ := filepath.Glob(filepath.Join(dir, "*", "*.jsonl"))
	if len(entries) != 0 {
		t.Errorf("unexpected files written: %v", entries)
	}
}

func TestHandlePushRejectsForeignHost(t *testing.T) {
	d, dir := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"host": "other-machine"}))
	if w.Code != http.StatusForbidden {
		t.Fatalf("foreign-host push: expected 403, got %d body=%s", w.Code, w.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "sync", "events-other-machine.jsonl")); err == nil {
		t.Fatal("foreign shard was created — single-writer invariant broken")
	}
}

func TestHandlePushRejectsJunkULID(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"id": "zzzz"}))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for junk ULID, got %d", w.Code)
	}
}

func TestHandlePushRejectsWrongSchemaVersion(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"v": 2}))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for v=2, got %d", w.Code)
	}
}

func TestHandlePushRequiresAgent(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"agent": ""}))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing agent, got %d", w.Code)
	}
}

func TestHandlePushRejectsBadPriority(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"priority": "P9"}))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for P9, got %d", w.Code)
	}
}

func TestHandlePushRejectsBadLabels(t *testing.T) {
	d, _ := newTestDaemon(t)
	for _, over := range []map[string]any{
		{"kind": "no spaces"},
		{"scope": "-lead"},
		{"agent": "tab\there"},
	} {
		w := doPush(t, d, pushBody(over))
		if w.Code != http.StatusBadRequest {
			t.Errorf("%v: expected 400, got %d", over, w.Code)
		}
	}
}

func TestHandlePushOversizeBody(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"filler": strings.Repeat("a", maxPushBody)}))
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", w.Code)
	}
}

func TestHandlePushTruncatesLongSummary(t *testing.T) {
	d, _ := newTestDaemon(t)
	long := strings.Repeat("s", 900)
	w := doPush(t, d, pushBody(map[string]any{"summary": long}))
	if w.Code != http.StatusOK {
		t.Fatalf("push: %d body=%s", w.Code, w.Body.String())
	}
	raw, err := os.ReadFile(filepath.Join(d.syncDir, "events-test-host.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var ev map[string]any
	if err := json.Unmarshal(raw[:len(raw)-1], &ev); err != nil {
		t.Fatal(err)
	}
	sum, _ := ev["summary"].(string)
	if len([]rune(sum)) > 500 {
		t.Fatalf("summary not truncated: %d runes", len([]rune(sum)))
	}
	if tr, _ := ev["truncated"].(bool); !tr {
		t.Fatal("truncated flag not set")
	}
}

func TestPushTruncationBeforeRedactionLeaksPassword(t *testing.T) {
	summary, password := dbURLAtCapBoundary()
	if red, _ := redact.Apply(summary); strings.Contains(red, password) {
		t.Fatal("precondition: the untruncated summary must be redactable")
	}
	d, _ := newTestDaemon(t)
	if w := doPush(t, d, pushBody(map[string]any{"summary": summary})); w.Code != http.StatusOK {
		t.Fatalf("push: %d %s", w.Code, w.Body.String())
	}
	if line := rawShardLines(t, d)[0]; strings.Contains(line, password) {
		t.Fatalf("db password written to the synced shard in plaintext: truncation cut the '@host' the db_url rule needs")
	}
}

func TestPushRedactionInflatesSummaryPastCap(t *testing.T) {
	d, _ := newTestDaemon(t)
	summary := strings.TrimSpace(strings.Repeat("10.0.0.1 ", 55))
	if w := doPush(t, d, pushBody(map[string]any{"summary": summary})); w.Code != http.StatusOK {
		t.Fatalf("push: %d %s", w.Code, w.Body.String())
	}
	var ev map[string]any
	if err := json.Unmarshal([]byte(rawShardLines(t, d)[0]), &ev); err != nil {
		t.Fatal(err)
	}
	stored, _ := ev["summary"].(string)
	if n := len([]rune(stored)); n > event.MaxSummaryRunes {
		t.Fatalf("stored summary is %d runes (cap %d, truncated=%v): redaction markers are added after the cap is applied", n, event.MaxSummaryRunes, ev["truncated"])
	}
}

func TestHandlePushRedactsAndAudits(t *testing.T) {
	d, _ := newTestDaemon(t)
	secret := "ghp_" + strings.Repeat("A", 36)
	w := doPush(t, d, pushBody(map[string]any{
		"id": "01HRX0000000000000000000T2", "summary": "token is " + secret, "session_id": "sess-1",
	}))
	if w.Code != http.StatusOK {
		t.Fatalf("push: %d body=%s", w.Code, w.Body.String())
	}
	raw, err := os.ReadFile(filepath.Join(d.syncDir, "events-test-host.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), secret) {
		t.Fatalf("secret survived push into shard: %s", raw)
	}
	if !strings.Contains(string(raw), "REDACTED:github_token") {
		t.Errorf("expected redaction marker in shard, got: %s", raw)
	}
	if !strings.Contains(string(raw), `"session_id":"sess-1"`) {
		t.Errorf("extended field dropped: %s", raw)
	}
	audits, _ := filepath.Glob(filepath.Join(d.stateDir, "audit", "redactions-*.jsonl"))
	if len(audits) != 1 {
		t.Fatalf("expected one audit file, got %v", audits)
	}
	ab, _ := os.ReadFile(audits[0])
	if !strings.Contains(string(ab), "01HRX0000000000000000000T2") || !strings.Contains(string(ab), "github_token") {
		t.Fatalf("audit row incomplete: %s", ab)
	}
	if strings.Contains(string(ab), secret) {
		t.Fatal("audit log must never contain the original secret")
	}
}

func TestRoutesRejectDNSRebindingWrite(t *testing.T) {
	d, _ := newTestDaemon(t)
	req := httptest.NewRequest(http.MethodPost, "http://rebind.attacker.example:7459/push", strings.NewReader(pushBody(nil)))
	req.Header.Set("Origin", "http://rebind.attacker.example:7459")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	d.routes().ServeHTTP(w, req)
	if w.Code != http.StatusMisdirectedRequest {
		t.Fatalf("browser write from a DNS-rebound origin (Host %q) got %d, want 421", req.Host, w.Code)
	}
	if _, err := os.Stat(filepath.Join(d.syncDir, "events-test-host.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("write from a DNS-rebound origin reached the shard (stat err=%v)", err)
	}
}

func TestRoutesRejectDNSRebindingRead(t *testing.T) {
	d, _ := newTestDaemon(t)
	if w := doPush(t, d, pushBody(map[string]any{"summary": "private work item"})); w.Code != http.StatusOK {
		t.Fatalf("seed push: %d", w.Code)
	}
	req := httptest.NewRequest(http.MethodGet, "http://rebind.attacker.example:7459/recent?hours=24", nil)
	req.Header.Set("Origin", "http://rebind.attacker.example:7459")
	w := httptest.NewRecorder()
	d.routes().ServeHTTP(w, req)
	if w.Code != http.StatusMisdirectedRequest || strings.Contains(w.Body.String(), "private work item") {
		t.Fatalf("activity log served to a non-loopback Host %q: %d %s", req.Host, w.Code, w.Body.String())
	}
}

func TestRoutesServeOnlyLocalhostAndIPLiteralHosts(t *testing.T) {
	d, _ := newTestDaemon(t)
	cases := []struct {
		host string
		want int
	}{
		{"127.0.0.1:7459", http.StatusOK},
		{"localhost:7459", http.StatusOK},
		{"LocalHost", http.StatusOK},
		{"[::1]:7459", http.StatusOK},
		{"192.168.1.20:7459", http.StatusOK},
		{"127.0.0.1.nip.io:7459", http.StatusMisdirectedRequest},
		{"localhost.attacker.example", http.StatusMisdirectedRequest},
		{"rebind.attacker.example:7459", http.StatusMisdirectedRequest},
	}
	for _, c := range cases {
		req := httptest.NewRequest(http.MethodGet, "/health", nil)
		req.Host = c.host
		w := httptest.NewRecorder()
		d.routes().ServeHTTP(w, req)
		if w.Code != c.want {
			t.Errorf("Host %q: got %d, want %d", c.host, w.Code, c.want)
		}
	}
}

func TestHandlePushAcceptsOnlyPayloadsTheIndexCanReadBack(t *testing.T) {
	d, _ := newTestDaemon(t)
	nested := func(depth int) string { return strings.Repeat("[", depth) + strings.Repeat("]", depth) }
	cases := []struct {
		id   string
		x    string
		want int
	}{
		{"01HRX00000000000000000NP01", nested(1001), http.StatusBadRequest},
		{"01HRX00000000000000000NP02", nested(maxPushJSONDepth + 1), http.StatusBadRequest},
		{"01HRX00000000000000000NP03", "1e400", http.StatusBadRequest},
		{"01HRX00000000000000000NP04", "[-1e400]", http.StatusBadRequest},
		{"01HRX00000000000000000NP05", nested(maxPushJSONDepth), http.StatusOK},
		{"01HRX00000000000000000NP06", "[1.5,-1.7976931348623157e308,1e-400]", http.StatusOK},
	}
	accepted := 0
	for _, c := range cases {
		body := strings.Replace(pushBody(map[string]any{"id": c.id}), `{`, `{"x":`+c.x+`,`, 1)
		w := doPush(t, d, body)
		if w.Code != c.want {
			t.Fatalf("x=%.40s: got %d %s, want %d", c.x, w.Code, w.Body.String(), c.want)
		}
		if w.Code == http.StatusOK {
			accepted++
		}
	}
	if lines := rawShardLines(t, d); len(lines) != accepted {
		t.Fatalf("shard holds %d lines, want the %d accepted payloads", len(lines), accepted)
	}
	if n := recentCount(t, d); n != accepted {
		t.Fatalf("/recent shows %d events, want %d: every payload /push accepts must stay indexable", n, accepted)
	}
}

func TestHandlePushRejectsNonStringPriority(t *testing.T) {
	d, _ := newTestDaemon(t)
	w := doPush(t, d, pushBody(map[string]any{"priority": 1}))
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "priority") {
		t.Fatalf("priority=1: got %d %s, want 400 naming the field — the shard line would no longer decode into event.Event", w.Code, w.Body.String())
	}
}

func TestHandlePushAcceptsOnlyIntegersInIntegerFields(t *testing.T) {
	d, _ := newTestDaemon(t)
	for i, over := range []map[string]any{
		{"exit_code": 1.5},
		{"duration_ms": 2.5},
		{"clock_offset_ms": 0.5},
		{"exit_code": 1e20},
	} {
		over["id"] = ulidForIndex(i)
		if w := doPush(t, d, pushBody(over)); w.Code != http.StatusBadRequest {
			t.Errorf("%v: got %d %s, want 400 — the shard line would no longer decode into event.Event", over, w.Code, w.Body.String())
		}
	}
	if w := doPush(t, d, pushBody(map[string]any{"exit_code": 2, "duration_ms": 1500, "clock_offset_ms": -12})); w.Code != http.StatusOK {
		t.Fatalf("integer fields: got %d %s, want 200", w.Code, w.Body.String())
	}
	line := rawShardLines(t, d)[0]
	var e event.Event
	if err := json.Unmarshal([]byte(line), &e); err != nil {
		t.Fatalf("accepted push does not decode into event.Event: %v (%s)", err, line)
	}
	if e.ExitCode == nil || *e.ExitCode != 2 || e.DurationMS != 1500 || e.ClockOffsetMS != -12 {
		t.Fatalf("integer fields not stored exactly: %s", line)
	}
}

func TestHandlePushKeepsLargeIntegersExact(t *testing.T) {
	d, _ := newTestDaemon(t)
	body := strings.Replace(pushBody(nil), `{`, `{"ext_ts_ns":1759480000123456789,`, 1)
	if w := doPush(t, d, body); w.Code != http.StatusOK {
		t.Fatalf("push: %d %s", w.Code, w.Body.String())
	}
	if line := rawShardLines(t, d)[0]; !strings.Contains(line, `"ext_ts_ns":1759480000123456789`) {
		t.Fatalf("pushed integer 1759480000123456789 was rewritten through float64: %s", line)
	}
}

func TestHandlePushRejectsNonIntegerSchemaVersion(t *testing.T) {
	d, _ := newTestDaemon(t)
	for i, v := range []any{"2", "1", 1.9} {
		w := doPush(t, d, pushBody(map[string]any{"id": ulidForIndex(i), "v": v}))
		if w.Code != http.StatusBadRequest {
			t.Errorf("v=%#v: got %d, want 400 (only the integer 1 is supported)", v, w.Code)
		}
	}
}

func TestHandlePushRejectsNonObjectAndTrailingJSON(t *testing.T) {
	d, _ := newTestDaemon(t)
	for _, body := range []string{
		"null",
		"[]",
		`"event"`,
		pushBody(nil) + `{"id":"01HRX0000000000000000000T2"}`,
		pushBody(nil) + " trailing",
	} {
		if w := doPush(t, d, body); w.Code != http.StatusBadRequest {
			t.Errorf("body %.60q: got %d %s, want 400", body, w.Code, w.Body.String())
		}
	}
	if w := doPush(t, d, pushBody(nil)+"\n"); w.Code != http.StatusOK {
		t.Fatalf("object with a trailing newline: got %d %s, want 200", w.Code, w.Body.String())
	}
}

func TestHandlePushAppendsConcurrentRetriesOfOneULIDOnce(t *testing.T) {
	d, _ := newTestDaemon(t)
	body := pushBody(map[string]any{"id": "01HRX00000000000000000D9P1"})
	const retries = 8
	recs := make([]*httptest.ResponseRecorder, retries)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := range recs {
		recs[i] = httptest.NewRecorder()
		wg.Add(1)
		go func(w *httptest.ResponseRecorder) {
			defer wg.Done()
			<-start
			d.handlePush(w, httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(body)))
		}(recs[i])
	}
	close(start)
	wg.Wait()
	if lines := rawShardLines(t, d); len(lines) != 1 {
		t.Fatalf("%d concurrent retries of one ULID appended %d shard lines (want 1) — `activity-log query` double-counts", retries, len(lines))
	}
	duplicates := 0
	for _, w := range recs {
		if w.Code != http.StatusOK {
			t.Fatalf("retry answered %d %s, want 200", w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), `"duplicate":true`) {
			duplicates++
		}
	}
	if duplicates != retries-1 {
		t.Fatalf("%d of %d retries flagged as duplicate, want %d", duplicates, retries, retries-1)
	}
}

func TestHandlePushRetryAfterCrashBeforeIngestAppendsOnce(t *testing.T) {
	d, _ := newTestDaemon(t)
	id := "01HRX00000000000000000CR01"
	seedJSONL(t, d.syncDir, "test-host", []map[string]any{
		{"v": 1, "id": id, "ts": tsNow(0), "host": "test-host", "agent": "pusher", "kind": "note", "scope": "s", "summary": "x"},
	})
	w := doPush(t, d, pushBody(map[string]any{"id": id}))
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"duplicate":true`) {
		t.Fatalf("retry of a ULID already in the shard but not yet indexed: got %d %s, want 200 with duplicate", w.Code, w.Body.String())
	}
	if lines := rawShardLines(t, d); len(lines) != 1 {
		t.Fatalf("retry appended a second copy: %d shard lines", len(lines))
	}
	if got := d.m.ingested.Load(); got != 1 {
		t.Fatalf("ingested_events_total=%d after indexing one event, want 1", got)
	}
	if w := doPush(t, d, pushBody(map[string]any{"id": "01HRX00000000000000000CR02"})); w.Code != http.StatusOK {
		t.Fatalf("next push: %d %s", w.Code, w.Body.String())
	}
	if got := d.m.ingested.Load(); got != 2 {
		t.Fatalf("ingested_events_total=%d after indexing two events, want 2: the pre- and post-push ingests must not count one event twice", got)
	}
}

func TestHandlePushIntoAHostWithoutAShardCountsNoError(t *testing.T) {
	d, _ := newTestDaemon(t)
	if w := doPush(t, d, pushBody(nil)); w.Code != http.StatusOK {
		t.Fatalf("push: %d %s", w.Code, w.Body.String())
	}
	if n := d.m.errors.Load(); n != 0 {
		t.Fatalf("first push into a host without a shard counted %d errors: a missing shard is not an ingest failure", n)
	}
}
