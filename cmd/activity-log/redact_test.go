package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactEventLine_UnchangedKeepsExactBytes(t *testing.T) {
	line := []byte(`{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","ts":"2026-07-07T00:00:00.000000Z","host":"h","agent":"a","kind":"note","scope":"s","summary":"nothing secret here"}`)
	out, changed, isEvent := redactEventLine(line)
	if !isEvent || changed {
		t.Fatalf("expected unchanged event: changed=%v isEvent=%v", changed, isEvent)
	}
	if string(out) != string(line) {
		t.Errorf("unchanged event mutated:\n in=%s\nout=%s", line, out)
	}
}

func TestRedactEventLine_RedactsSecret(t *testing.T) {
	secret := "ghp_" + strings.Repeat("A", 36)
	line := []byte(`{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","ts":"2026-07-07T00:00:00.000000Z","host":"h","kind":"note","scope":"s","summary":"token ` + secret + `"}`)
	out, changed, isEvent := redactEventLine(line)
	if !isEvent || !changed {
		t.Fatalf("expected changed event: changed=%v isEvent=%v", changed, isEvent)
	}
	if strings.Contains(string(out), secret) {
		t.Errorf("secret survived: %s", out)
	}
	if !strings.Contains(string(out), "REDACTED:github_token") {
		t.Errorf("missing redaction marker: %s", out)
	}
}

func TestRedactShard_ScrubsAndPreserves(t *testing.T) {
	dir := t.TempDir()
	store := filepath.Join(dir, "store")
	if err := os.MkdirAll(store, 0o755); err != nil {
		t.Fatal(err)
	}
	shard := filepath.Join(dir, "events-h.jsonl")
	secret := "ghp_" + strings.Repeat("B", 36)
	clean := `{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G5FA1","ts":"2026-07-07T00:00:00.000000Z","host":"h","kind":"note","scope":"s","summary":"fine"}`
	leaky := `{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G5FA2","ts":"2026-07-07T00:00:01.000000Z","host":"h","kind":"note","scope":"s","summary":"key ` + secret + `"}`
	body := clean + "\n" + leaky + "\n" + "{malformed tail"
	if err := os.WriteFile(shard, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := redactShard(shard, store, "h", false)
	if err != nil {
		t.Fatal(err)
	}
	if res.events != 2 || res.changed != 1 || res.malformed != 1 {
		t.Fatalf("res = %+v, want events=2 changed=1 malformed=1", res)
	}
	got, _ := os.ReadFile(shard)
	gs := string(got)
	if strings.Contains(gs, secret) {
		t.Errorf("secret survived shard redaction: %s", gs)
	}
	if !strings.Contains(gs, clean) {
		t.Errorf("clean event not preserved byte-for-byte: %s", gs)
	}
	if !strings.Contains(gs, "{malformed tail") {
		t.Errorf("malformed tail dropped: %s", gs)
	}
}
