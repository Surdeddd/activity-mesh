// These tests hit the FTS5-backed index and need the sqlite_fts5 driver tag
// (CGO_ENABLED=1). Run via `make test`; plain `go test ./...` skips them.

//go:build sqlite_fts5

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Surdeddd/activity-mesh/pkg/index"
)

// newTestDaemon spins up a daemon backed by a temp index/sync dir but does
// NOT start the HTTP server / fsnotify loop — handlers are tested via httptest.
func newTestDaemon(t *testing.T) (*daemon, string) {
	t.Helper()
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "state")
	syncDir := filepath.Join(dir, "sync")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(syncDir, 0o755); err != nil {
		t.Fatal(err)
	}
	idx, err := index.NewIndex(filepath.Join(stateDir, "index.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = idx.Close() })
	d := &daemon{idx: idx, syncDir: syncDir, stateDir: stateDir}
	d.m.startedAt = time.Now().UTC()
	return d, dir
}

// seedJSONL writes lines into events-<host>.jsonl for the daemon.
func seedJSONL(t *testing.T, syncDir, host string, events []map[string]any) {
	t.Helper()
	path := filepath.Join(syncDir, "events-"+host+".jsonl")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, ev := range events {
		b, err := json.Marshal(ev)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.Write(append(b, '\n')); err != nil {
			t.Fatal(err)
		}
	}
}

func tsNow(offset time.Duration) string {
	return time.Now().UTC().Add(offset).Format("2006-01-02T15:04:05.000000Z")
}

func TestHandleHealth(t *testing.T) {
	d, _ := newTestDaemon(t)
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	d.handleHealth(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var got map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got["ok"] != true {
		t.Errorf("expected ok=true, got %+v", got)
	}
	if _, ok := got["uptime_seconds"]; !ok {
		t.Errorf("expected uptime_seconds key")
	}
}

func TestHandleRecent(t *testing.T) {
	d, _ := newTestDaemon(t)
	seedJSONL(t, d.syncDir, "macbook", []map[string]any{
		{"v": 1, "id": "01HRX0000000000000000000Q1", "ts": tsNow(-2 * time.Hour), "host": "macbook", "agent": "claude-mac", "scope": "project:openclaw", "kind": "decision", "summary": "alpha"},
		{"v": 1, "id": "01HRX0000000000000000000Q2", "ts": tsNow(-1 * time.Hour), "host": "macbook", "agent": "hermes", "scope": "project:hermes", "kind": "config", "summary": "beta"},
	})
	if _, err := d.idx.IngestDir(d.syncDir); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/recent?hours=24&limit=5", nil)
	w := httptest.NewRecorder()
	d.handleRecent(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Count  int           `json:"count"`
		Events []index.Event `json:"events"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Count != 2 {
		t.Errorf("expected 2 events, got %d", resp.Count)
	}

	// scope filter
	req2 := httptest.NewRequest(http.MethodGet, "/recent?scope=project:openclaw&hours=24", nil)
	w2 := httptest.NewRecorder()
	d.handleRecent(w2, req2)
	var resp2 struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal(w2.Body.Bytes(), &resp2)
	if resp2.Count != 1 {
		t.Errorf("expected 1 openclaw event, got %d", resp2.Count)
	}
}

func TestHandleSearch(t *testing.T) {
	d, _ := newTestDaemon(t)
	seedJSONL(t, d.syncDir, "macbook", []map[string]any{
		{"v": 1, "id": "01HRX0000000000000000000R1", "ts": tsNow(-2 * time.Hour), "host": "macbook", "agent": "cli", "scope": "scope:test", "kind": "note", "summary": "fixed billing proxy bug"},
		{"v": 1, "id": "01HRX0000000000000000000R2", "ts": tsNow(-1 * time.Hour), "host": "macbook", "agent": "cli", "scope": "scope:test", "kind": "note", "summary": "drafted plan for hermes onboarding"},
	})
	if _, err := d.idx.IngestDir(d.syncDir); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/search?q=billing&limit=5", nil)
	w := httptest.NewRecorder()
	d.handleSearch(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Count != 1 {
		t.Errorf("expected 1 hit, got %d", resp.Count)
	}

	// missing q -> 400
	req2 := httptest.NewRequest(http.MethodGet, "/search", nil)
	w2 := httptest.NewRecorder()
	d.handleSearch(w2, req2)
	if w2.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w2.Code)
	}
}

func TestHandleDigestMarkdown(t *testing.T) {
	d, _ := newTestDaemon(t)
	seedJSONL(t, d.syncDir, "macbook", []map[string]any{
		{"v": 1, "id": "01HRX0000000000000000000S1", "ts": tsNow(-1 * time.Hour), "host": "macbook", "scope": "project:openclaw", "kind": "note", "agent": "cli", "summary": "x"},
		{"v": 1, "id": "01HRX0000000000000000000S2", "ts": tsNow(-30 * time.Minute), "host": "macbook", "scope": "project:openclaw", "kind": "note", "agent": "cli", "summary": "y"},
		{"v": 1, "id": "01HRX0000000000000000000S3", "ts": tsNow(-15 * time.Minute), "host": "macbook", "scope": "project:hermes", "kind": "note", "agent": "cli", "summary": "z"},
	})
	if _, err := d.idx.IngestDir(d.syncDir); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/digest?window=24h&group_by=scope", nil)
	w := httptest.NewRecorder()
	d.handleDigest(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("digest md: %d body=%s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, "project:openclaw") || !strings.Contains(body, "project:hermes") {
		t.Errorf("digest missing scopes: %s", body)
	}

	// JSON variant
	req2 := httptest.NewRequest(http.MethodGet, "/digest?window=24h&group_by=scope&format=json", nil)
	w2 := httptest.NewRecorder()
	d.handleDigest(w2, req2)
	var got map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &got); err != nil {
		t.Fatalf("digest json decode: %v", err)
	}
	if got["window"] != "24h" {
		t.Errorf("expected window=24h, got %+v", got)
	}
}

func TestHandlePush(t *testing.T) {
	d, _ := newTestDaemon(t)
	body := map[string]any{
		"v":       1,
		"id":      "01HRX0000000000000000000T1",
		"ts":      tsNow(0),
		"host":    "test-host",
		"kind":    "note",
		"scope":   "scope:test",
		"summary": "hello via push",
	}
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(string(b)))
	w := httptest.NewRecorder()
	d.handlePush(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("push expected 200, got %d body=%s", w.Code, w.Body.String())
	}
	// Verify shard exists
	shard := filepath.Join(d.syncDir, "events-test-host.jsonl")
	if _, err := os.Stat(shard); err != nil {
		t.Fatalf("shard missing: %v", err)
	}
	// Verify recent picks it up (eager ingest happens inside handler)
	req2 := httptest.NewRequest(http.MethodGet, "/recent?host=test-host", nil)
	w2 := httptest.NewRecorder()
	d.handleRecent(w2, req2)
	var resp struct {
		Count int `json:"count"`
	}
	_ = json.Unmarshal(w2.Body.Bytes(), &resp)
	if resp.Count != 1 {
		t.Errorf("expected 1 event after push, got %d", resp.Count)
	}

	// missing fields -> 400
	bad, _ := json.Marshal(map[string]any{"id": "x"})
	req3 := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(string(bad)))
	w3 := httptest.NewRecorder()
	d.handlePush(w3, req3)
	if w3.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w3.Code)
	}

	// wrong method -> 405
	req4 := httptest.NewRequest(http.MethodGet, "/push", nil)
	w4 := httptest.NewRecorder()
	d.handlePush(w4, req4)
	if w4.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", w4.Code)
	}
}

func TestHandleMetrics(t *testing.T) {
	d, _ := newTestDaemon(t)
	d.m.queries.Add(3)
	d.m.errors.Add(1)
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()
	d.handleMetrics(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("metrics expected 200, got %d", w.Code)
	}
	body := w.Body.String()
	if !strings.Contains(body, "activity_mesh_queries_total 3") {
		t.Errorf("queries metric missing: %s", body)
	}
	if !strings.Contains(body, "activity_mesh_errors_total 1") {
		t.Errorf("errors metric missing: %s", body)
	}
}

// TestIntegration_FsnotifyToHTTP: spin up the full daemon (server + watcher),
// write 100 events to JSONL, verify HTTP /recent picks them up.
func TestIntegration_FsnotifyToHTTP(t *testing.T) {
	if testing.Short() {
		t.Skip("skipped in -short")
	}
	d, _ := newTestDaemon(t)

	// Construct an HTTP server bound to a free port (port 0 -> kernel-chosen).
	mux := http.NewServeMux()
	mux.HandleFunc("/health", d.handleHealth)
	mux.HandleFunc("/recent", d.handleRecent)
	mux.HandleFunc("/push", d.handlePush)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	// Spawn the fsnotify loop in a context.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.watchSync(ctx)

	// Give the watcher a moment to register.
	time.Sleep(100 * time.Millisecond)

	// Append 100 events directly to the per-host JSONL — daemon should pick up.
	now := time.Now().UTC()
	events := make([]map[string]any, 0, 100)
	for i := 0; i < 100; i++ {
		events = append(events, map[string]any{
			"v":       1,
			"id":      fmt.Sprintf("01HRX0000000000000000IT%04d", i),
			"ts":      now.Add(time.Duration(-i) * time.Second).Format("2006-01-02T15:04:05.000000Z"),
			"host":    "macbook",
			"agent":   "cli",
			"scope":   "scope:integration",
			"kind":    "note",
			"summary": fmt.Sprintf("integration test event %d", i),
		})
	}
	seedJSONL(t, d.syncDir, "macbook", events)

	// Wait until the watcher has ingested all 100 events (debounce + tick + ingest).
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		stats, _ := d.idx.Stats()
		if stats.TotalEvents >= 100 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	stats, _ := d.idx.Stats()
	if stats.TotalEvents < 100 {
		t.Fatalf("watcher did not ingest 100 events: total=%d", stats.TotalEvents)
	}

	// HTTP smoke
	resp, err := http.Get(srv.URL + "/recent?scope=scope:integration&hours=24&limit=200")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status: %d", resp.StatusCode)
	}
	var got struct {
		Count int `json:"count"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Count != 100 {
		t.Errorf("expected 100 recent events, got %d", got.Count)
	}
}

