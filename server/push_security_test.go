// /push hardening regressions: path traversal, junk ULIDs, redaction bypass.


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

// TestHandlePushRejectsTraversalHost — a host label with path separators or
// dot-dot must never reach the filesystem (P0: arbitrary file append).
func TestHandlePushRejectsTraversalHost(t *testing.T) {
	d, dir := newTestDaemon(t)
	for _, host := range []string{"../../evil", "a/b", "..", ".hidden/../..", "x\\y", ""} {
		body, _ := json.Marshal(map[string]any{
			"v": 1, "id": "01HRX0000000000000000000T1", "ts": tsNow(0),
			"host": host, "kind": "note", "scope": "s", "summary": "x",
		})
		req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(string(body)))
		w := httptest.NewRecorder()
		d.handlePush(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("host %q: expected 400, got %d", host, w.Code)
		}
	}
	// nothing may have been written anywhere under the temp root
	entries, _ := filepath.Glob(filepath.Join(dir, "*", "*.jsonl"))
	if len(entries) != 0 {
		t.Errorf("unexpected files written: %v", entries)
	}
}

// TestHandlePushRejectsJunkULID — a junk id would permanently win MAX(ulid).
func TestHandlePushRejectsJunkULID(t *testing.T) {
	d, _ := newTestDaemon(t)
	body, _ := json.Marshal(map[string]any{
		"v": 1, "id": "zzzz", "ts": tsNow(0),
		"host": "test-host", "kind": "note", "scope": "s", "summary": "x",
	})
	req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(string(body)))
	w := httptest.NewRecorder()
	d.handlePush(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for junk ULID, got %d", w.Code)
	}
}

// TestHandlePushRedacts — pushes must not be a side door around redaction,
// and extended schema fields must survive the generic-map path.
func TestHandlePushRedacts(t *testing.T) {
	d, _ := newTestDaemon(t)
	secret := "ghp_" + strings.Repeat("A", 36)
	body, _ := json.Marshal(map[string]any{
		"v": 1, "id": "01HRX0000000000000000000T2", "ts": tsNow(0),
		"host": "test-host", "kind": "note", "scope": "s",
		"summary": "token is " + secret, "session_id": "sess-1",
	})
	req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(string(body)))
	w := httptest.NewRecorder()
	d.handlePush(w, req)
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
}
