package shard

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidHost(t *testing.T) {
	good := []string{"MacBook-Pro-Maksim.local", "mini", "host_1", "a.b-c"}
	for _, h := range good {
		if !ValidHost(h) {
			t.Errorf("ValidHost(%q) = false, want true", h)
		}
	}
	bad := []string{"", "..", "a/b", `a\b`, "../x", "a..b", ".hidden", "-lead", "a b", "хост"}
	for _, h := range bad {
		if ValidHost(h) {
			t.Errorf("ValidHost(%q) = true, want false", h)
		}
	}
}

func TestIsShardName(t *testing.T) {
	live := []string{"events-mini.jsonl", "events-MacBook-Pro-Maksim.local.jsonl", "events-host_1.jsonl", "events-a.b-c.jsonl"}
	for _, n := range live {
		if !IsShardName(n) {
			t.Errorf("IsShardName(%q) = false, want true", n)
		}
	}
	notShards := []string{
		"events-mini.sync-conflict-20261003-010203-ABCDEFG.jsonl",
		"events-MacBook-Pro-Maksim.local.sync-conflict-20261003-010203-ABCDEFG.jsonl",
		"events-mini.jsonl.gz",
		"events-mini.jsonl.tmp",
		"events-mini.json",
		"events-mini",
		"mini.jsonl",
		"scopes.yaml",
		".syncthing.events-mini.jsonl.tmp",
		"",
	}
	for _, n := range notShards {
		if IsShardName(n) {
			t.Errorf("IsShardName(%q) = true, want false", n)
		}
	}
}

func TestIsShardNameAcceptsEveryPathItBuilds(t *testing.T) {
	for _, host := range []string{"MacBook-Pro-Maksim.local", "mini", "host_1", "a.b-c"} {
		p, err := Path("/sync", host)
		if err != nil {
			t.Fatal(err)
		}
		if name := filepath.Base(p); !IsShardName(name) {
			t.Errorf("IsShardName(%q) = false for the shard Path built for host %q", name, host)
		}
	}
}

func TestPathRejectsTraversal(t *testing.T) {
	if _, err := Path("/sync", "../../etc/cron.d/evil"); err == nil {
		t.Fatal("expected error for traversal host")
	}
	p, err := Path("/sync", "mini")
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join("/sync", "events-mini.jsonl") {
		t.Errorf("unexpected path %q", p)
	}
}

func TestAppendLockedHealsTornTail(t *testing.T) {
	dir := t.TempDir()
	shardPath := filepath.Join(dir, "events-h1.jsonl")
	if err := os.WriteFile(shardPath, []byte(`{"id":"aaa"}`+"\n"+`{"id":"partial`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := AppendLocked(dir, "h1", []byte(`{"id":"bbb"}`)); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(shardPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines (healed tail), got %d: %q", len(lines), raw)
	}
	if lines[2] != `{"id":"bbb"}` {
		t.Errorf("appended line corrupted: %q", lines[2])
	}
	if !strings.HasSuffix(string(raw), "\n") {
		t.Error("shard must end with newline after append")
	}
}

func TestAppendLockedPlain(t *testing.T) {
	dir := t.TempDir()
	if err := AppendLocked(dir, "h2", []byte(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := AppendLocked(dir, "h2", []byte(`{"b":2}`)); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "events-h2.jsonl"))
	if string(raw) != `{"a":1}`+"\n"+`{"b":2}`+"\n" {
		t.Errorf("unexpected shard content: %q", raw)
	}
}
