package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
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

func TestRedactShardExpandsTildeInSyncDir(t *testing.T) {
	_, _, home := sandboxEnv(t)
	t.Setenv("USERPROFILE", home)
	alt := filepath.Join(home, "alt")
	if err := os.MkdirAll(alt, 0o755); err != nil {
		t.Fatal(err)
	}
	token := "ghp_" + strings.Repeat("A", 36)
	shardPath := filepath.Join(alt, "events-"+event.HostName()+".jsonl")
	line := fmt.Sprintf(`{"v":1,"id":"01HRX0000000000000000000R1","ts":"2026-10-01T00:00:00.000000Z","host":%q,"agent":"a","kind":"note","scope":"s","summary":"leak %s"}`+"\n", event.HostName(), token)
	if err := os.WriteFile(shardPath, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := redactShardCmd()
	cmd.SilenceErrors, cmd.SilenceUsage = true, true
	cmd.SetArgs([]string{"--sync-dir", "~/alt"})
	out, err := captureStdout(t, cmd.Execute)
	if err != nil {
		t.Fatalf("redact-shard --sync-dir '~/alt': %v", err)
	}
	raw, _ := os.ReadFile(shardPath)
	if strings.Contains(string(raw), token) {
		t.Fatalf("redact-shard --sync-dir '~/alt' reported %q but the token is still in %s", strings.TrimSpace(out), shardPath)
	}
	if !strings.Contains(out, "redacted 1 of 1 events") {
		t.Errorf("unexpected report %q", out)
	}
}

func TestRedactShardFailsWhenThisHostHasNoShard(t *testing.T) {
	syncDir, _, _ := sandboxEnv(t)
	want := "no shard for this host at " + filepath.Join(syncDir, "events-"+event.HostName()+".jsonl")
	for _, args := range [][]string{{}, {"--dry-run"}} {
		cmd := redactShardCmd()
		cmd.SilenceErrors, cmd.SilenceUsage = true, true
		cmd.SetArgs(args)
		out, err := captureStdout(t, cmd.Execute)
		if err == nil || err.Error() != want {
			t.Errorf("args %v: err = %v (stdout %q), want %q", args, err, out, want)
		}
	}
}

func TestRedactEventLineKeepsNumberLiteralsExact(t *testing.T) {
	token := "ghp_" + strings.Repeat("B", 36)
	line := []byte(`{"v":1,"id":"01HRX0000000000000000000R2","ts":"2026-10-01T00:00:00.000000Z","host":"h","agent":"a","kind":"note","scope":"s","summary":"leak ` + token + `","ext_ts_ns":1759480000123456789,"huge":12345678901234567890123,"ratio":1.50}`)
	out, changed, isEvent := redactEventLine(line)
	if !isEvent || !changed {
		t.Fatalf("precondition: the line carries a secret and must be rewritten (changed=%v isEvent=%v)", changed, isEvent)
	}
	if strings.Contains(string(out), token) {
		t.Fatalf("secret survived: %s", out)
	}
	for _, literal := range []string{`"ext_ts_ns":1759480000123456789`, `"huge":12345678901234567890123`, `"ratio":1.50`} {
		if !strings.Contains(string(out), literal) {
			t.Errorf("redact-shard altered a non-secret number, missing %s in %s", literal, out)
		}
	}
}

func TestRedactEventLineTreatsTrailingDataAsMalformed(t *testing.T) {
	secret := "ghp_" + strings.Repeat("C", 36)
	for _, tail := range []string{` junk`, `{"id":"second"}`, ` 1`} {
		line := []byte(`{"v":1,"id":"01HRX0000000000000000000R3","summary":"key ` + secret + `"}` + tail)
		out, changed, isEvent := redactEventLine(line)
		if isEvent || changed || string(out) != string(line) {
			t.Errorf("tail %q: isEvent=%v changed=%v out=%s, want the line preserved verbatim as malformed", tail, isEvent, changed, out)
		}
	}
}
