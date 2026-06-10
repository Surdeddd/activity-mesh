// Package tests holds black-box scenario tests that exercise the built
// binaries end-to-end. Untagged on purpose: they must run under plain
// `go test ./...` as well as `make test` (sqlite_fts5).
package tests

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// buildActivityLog compiles the CLI into a temp dir and returns its path.
func buildActivityLog(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "activity-log")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	cmd := exec.Command("go", "build", "-o", bin, "./cmd/activity-log")
	cmd.Dir = ".." // module root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/activity-log: %v\n%s", err, out)
	}
	return bin
}

func writeShard(t *testing.T, syncDir, host string, lines []string) {
	t.Helper()
	path := filepath.Join(syncDir, "events-"+host+".jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func eventLine(t *testing.T, ts time.Time, host, scope, summary string, seq uint64) string {
	t.Helper()
	ev := map[string]any{
		"v":             1,
		"id":            fmt.Sprintf("01TESTULID%016d", seq),
		"ts":            ts.UTC().Format("2006-01-02T15:04:05.000000Z"),
		"host":          host,
		"agent":         "test",
		"kind":          "note",
		"scope":         scope,
		"summary":       summary,
		"monotonic_seq": seq,
	}
	buf, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	return string(buf)
}

// TestQueryWorksWithNoDaemon proves the ARCHITECTURE.md claim that the
// query path is daemon-independent: `activity-log query` reads the JSONL
// shards in the sync dir directly. No daemon is started here, and the sync
// dir is a fresh temp dir no daemon could ever have indexed — so any correct
// result can only have come from direct local reads.
func TestQueryWorksWithNoDaemon(t *testing.T) {
	bin := buildActivityLog(t)

	dir := t.TempDir()
	syncDir := filepath.Join(dir, "sync")
	storeDir := filepath.Join(dir, "store")
	for _, d := range []string{syncDir, storeDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cfgPath := filepath.Join(dir, "config.json")
	cfg := fmt.Sprintf(`{"sync_dir":%q,"store_dir":%q}`, syncDir, storeDir)
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}

	// Synthetic events across two host shards: three fresh, one stale (out of
	// the 24h window), one in a different scope.
	now := time.Now().UTC()
	writeShard(t, syncDir, "alpha", []string{
		eventLine(t, now.Add(-2*time.Hour), "alpha", "project:mesh", "fresh alpha event", 1),
		eventLine(t, now.Add(-48*time.Hour), "alpha", "project:mesh", "stale alpha event", 2),
	})
	writeShard(t, syncDir, "beta", []string{
		eventLine(t, now.Add(-1*time.Hour), "beta", "project:mesh", "fresh beta event", 1),
		eventLine(t, now.Add(-30*time.Minute), "beta", "project:other", "other-scope beta event", 2),
	})

	run := func(args ...string) string {
		t.Helper()
		cmd := exec.Command(bin, append([]string{"--config", cfgPath}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("activity-log %s: %v\n%s", strings.Join(args, " "), err, out)
		}
		return string(out)
	}

	// 1. Default 24h window merges both shards, drops the stale event, and
	//    sorts ascending by ts.
	out := run("query", "--since", "24h", "--format", "json")
	var got []map[string]any
	dec := json.NewDecoder(strings.NewReader(out))
	for dec.More() {
		var ev map[string]any
		if err := dec.Decode(&ev); err != nil {
			t.Fatalf("decode query output: %v\noutput:\n%s", err, out)
		}
		got = append(got, ev)
	}
	if len(got) != 3 {
		t.Fatalf("query --since 24h returned %d events, want 3\noutput:\n%s", len(got), out)
	}
	wantOrder := []string{"fresh alpha event", "fresh beta event", "other-scope beta event"}
	for i, want := range wantOrder {
		if got[i]["summary"] != want {
			t.Errorf("event[%d].summary = %q, want %q", i, got[i]["summary"], want)
		}
	}
	if strings.Contains(out, "stale alpha event") {
		t.Error("stale event leaked past the --since 24h window")
	}

	// 2. Scope filter narrows correctly across shards.
	out = run("query", "--since", "24h", "--scope", "project:mesh", "--format", "text")
	if !strings.Contains(out, "fresh alpha event") || !strings.Contains(out, "fresh beta event") {
		t.Errorf("scope filter lost fresh events:\n%s", out)
	}
	if strings.Contains(out, "other-scope beta event") {
		t.Errorf("scope filter leaked foreign scope:\n%s", out)
	}

	// 3. status also reads shards directly.
	out = run("status")
	if !strings.Contains(out, "alpha:") || !strings.Contains(out, "beta:") {
		t.Errorf("status missing per-host lines:\n%s", out)
	}
}
