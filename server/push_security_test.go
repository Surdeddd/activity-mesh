package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
