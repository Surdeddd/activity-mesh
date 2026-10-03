package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Surdeddd/activity-mesh/pkg/index"
)

func pushWithHeaders(t *testing.T, d *daemon, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/push", strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	d.handlePush(w, req)
	return w
}

func shardLines(t *testing.T, dir string) []map[string]any {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(dir, "*", "events-*.jsonl"))
	if err != nil || len(matches) == 0 {
		t.Fatalf("no shard written (glob err=%v matches=%v)", err, matches)
	}
	buf, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(string(buf)), "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("bad shard line %q: %v", l, err)
		}
		out = append(out, m)
	}
	return out
}

// The host's writer owns ordering. A client-supplied monotonic_seq would sort
// its event ahead of every later CLI emit forever.
func TestHandlePushAssignsMonotonicSeqAndIgnoresClientValue(t *testing.T) {
	d, dir := newTestDaemon(t)

	w := doPush(t, d, pushBody(map[string]any{
		"id": "01HRX0000000000000000000S1", "monotonic_seq": 999999, "ts_mono_ns": 42, "boot_id": "forged",
	}))
	if w.Code != http.StatusOK {
		t.Fatalf("push: %d body=%s", w.Code, w.Body.String())
	}
	w2 := doPush(t, d, pushBody(map[string]any{"id": "01HRX0000000000000000000S2"}))
	if w2.Code != http.StatusOK {
		t.Fatalf("second push: %d body=%s", w2.Code, w2.Body.String())
	}

	lines := shardLines(t, dir)
	if len(lines) != 2 {
		t.Fatalf("expected 2 shard lines, got %d", len(lines))
	}
	first, _ := lines[0]["monotonic_seq"].(float64)
	second, _ := lines[1]["monotonic_seq"].(float64)
	if first == 0 || second == 0 {
		t.Fatalf("push left monotonic_seq unset: %v / %v", lines[0]["monotonic_seq"], lines[1]["monotonic_seq"])
	}
	if first == 999999 {
		t.Error("client-supplied monotonic_seq was written verbatim")
	}
	if second <= first {
		t.Errorf("seq not monotonic: %v then %v", first, second)
	}
	if _, ok := lines[0]["boot_id"]; ok {
		t.Error("client-supplied boot_id was persisted")
	}
	if _, ok := lines[0]["ts_mono_ns"]; ok {
		t.Error("client-supplied ts_mono_ns was persisted")
	}
}

// A retry after a dropped response must not append a second copy: the CLI reads
// the shard and would double-count what the ULID-keyed index shows once.
func TestHandlePushIsIdempotentPerULID(t *testing.T) {
	d, dir := newTestDaemon(t)
	body := pushBody(map[string]any{"id": "01HRX0000000000000000000D1"})

	if w := doPush(t, d, body); w.Code != http.StatusOK {
		t.Fatalf("first push: %d %s", w.Code, w.Body.String())
	}
	w2 := doPush(t, d, body)
	if w2.Code != http.StatusOK {
		t.Fatalf("retry push: %d %s", w2.Code, w2.Body.String())
	}

	if lines := shardLines(t, dir); len(lines) != 1 {
		t.Errorf("retry appended a duplicate: %d shard lines", len(lines))
	}
	var resp map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["duplicate"] != true {
		t.Errorf("retry response did not flag the duplicate: %v", resp)
	}
}

// A page the user merely visited must not be able to forge events that later
// get injected into an agent's context.
func TestHandlePushRejectsBrowserOriginatedWrites(t *testing.T) {
	d, _ := newTestDaemon(t)
	rejected := []map[string]string{
		{"Origin": "https://evil.example"},
		{"Origin": "null"},
		{"Sec-Fetch-Site": "cross-site"},
		{"Content-Type": "text/plain;charset=UTF-8"},
		{"Content-Type": "application/x-www-form-urlencoded"},
		{"Content-Type": "multipart/form-data; boundary=x"},
	}
	for _, h := range rejected {
		w := pushWithHeaders(t, d, pushBody(nil), h)
		if w.Code != http.StatusForbidden {
			t.Errorf("headers %v: expected 403, got %d (%s)", h, w.Code, w.Body.String())
		}
	}
}

// Scripted clients (curl, hooks, hermes) must keep working — they send neither
// Origin nor Sec-Fetch-Site, and may send no Content-Type at all.
func TestHandlePushAllowsScriptedClients(t *testing.T) {
	d, _ := newTestDaemon(t)
	allowed := []map[string]string{
		{},
		{"Content-Type": "application/json"},
		{"Sec-Fetch-Site": "same-origin"},
		{"User-Agent": "curl/8.4.0"},
	}
	for i, h := range allowed {
		body := pushBody(map[string]any{"id": ulidForIndex(i)})
		w := pushWithHeaders(t, d, body, h)
		if w.Code != http.StatusOK {
			t.Errorf("headers %v: expected 200, got %d (%s)", h, w.Code, w.Body.String())
		}
	}
}

func ulidForIndex(i int) string {
	return "01HRX0000000000000000000A" + string(rune('1'+i))
}

func TestHandlePushStoresTimestampAsCanonicalUTC(t *testing.T) {
	const canonical = "2006-01-02T15:04:05.000000Z"
	cases := []struct {
		name, sent, want string
	}{
		{"positive offset", "2026-10-04T10:00:00.5+03:00", "2026-10-04T07:00:00.500000Z"},
		{"negative offset", "2026-10-03T23:30:00-05:00", "2026-10-04T04:30:00.000000Z"},
		{"no fraction", "2026-10-04T07:00:00Z", "2026-10-04T07:00:00.000000Z"},
		{"nanoseconds", "2026-10-04T07:00:00.123456789Z", "2026-10-04T07:00:00.123456Z"},
		{"already canonical", "2026-10-04T07:00:00.123456Z", "2026-10-04T07:00:00.123456Z"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, _ := newTestDaemon(t)
			if w := doPush(t, d, pushBody(map[string]any{"ts": tc.sent})); w.Code != http.StatusOK {
				t.Fatalf("push: %d %s", w.Code, w.Body.String())
			}
			lines := rawShardLines(t, d)
			if len(lines) != 1 {
				t.Fatalf("want one shard line, got %d", len(lines))
			}
			var stored struct {
				TS string `json:"ts"`
			}
			if err := json.Unmarshal([]byte(lines[0]), &stored); err != nil {
				t.Fatal(err)
			}
			if stored.TS != tc.want {
				t.Errorf("shard ts = %q, want %q", stored.TS, tc.want)
			}
			wantAt, err := time.Parse(canonical, tc.want)
			if err != nil {
				t.Fatal(err)
			}
			indexed, err := d.idx.Query(index.QueryFilter{Limit: 1})
			if err != nil || len(indexed) != 1 {
				t.Fatalf("index query: %v, %d rows", err, len(indexed))
			}
			if indexed[0].TS != tc.want || indexed[0].TSUnix != wantAt.Unix() {
				t.Errorf("indexed ts = %q (unix %d), want %q (unix %d)", indexed[0].TS, indexed[0].TSUnix, tc.want, wantAt.Unix())
			}
		})
	}
}
