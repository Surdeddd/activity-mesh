package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/shard"
)

func setupTempEnv(t *testing.T) (storeDir, syncDir string) {
	t.Helper()
	dir := t.TempDir()
	storeDir = filepath.Join(dir, "store")
	syncDir = filepath.Join(dir, "sync")
	if err := os.MkdirAll(storeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(syncDir, 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func emitOne(t *testing.T, storeDir, syncDir string, summary string) *event.Event {
	t.Helper()
	ev, err := event.New(storeDir, "note", "scope:test", summary)
	if err != nil {
		t.Fatalf("event.New: %v", err)
	}
	line, _, err := ev.Marshal()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := shard.AppendLocked(syncDir, ev.Host, line); err != nil {
		t.Fatalf("shard.AppendLocked: %v", err)
	}
	return ev
}

func readShard(t *testing.T, syncDir, host string) []event.Event {
	t.Helper()
	path := filepath.Join(syncDir, "events-"+host+".jsonl")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	var out []event.Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var ev event.Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("decode: %v (line=%s)", err, line)
		}
		out = append(out, ev)
	}
	return out
}

func TestEmitQueryRoundtrip(t *testing.T) {
	storeDir, syncDir := setupTempEnv(t)
	ev := emitOne(t, storeDir, syncDir, "smoke roundtrip")
	got := readShard(t, syncDir, ev.Host)
	if len(got) != 1 {
		t.Fatalf("expected 1 event, got %d", len(got))
	}
	if got[0].ID != ev.ID || got[0].Summary != "smoke roundtrip" {
		t.Errorf("mismatch: in=%+v out=%+v", ev, got[0])
	}
	if got[0].MonotonicSeq == 0 {
		t.Errorf("expected monotonic_seq>=1")
	}
}

func TestRedactionInJSONL(t *testing.T) {
	storeDir, syncDir := setupTempEnv(t)
	leak := "sk-ant-api03-" + strings.Repeat("X", 93) + "AA"
	ev := emitOne(t, storeDir, syncDir, "API key "+leak+" leak")
	got := readShard(t, syncDir, ev.Host)
	if len(got) != 1 {
		t.Fatalf("expected 1 event")
	}
	if strings.Contains(got[0].Summary, leak) {
		t.Errorf("secret leaked to disk: %q", got[0].Summary)
	}
	if !strings.Contains(got[0].Summary, "[REDACTED:") {
		t.Errorf("expected redaction marker in summary, got: %q", got[0].Summary)
	}
}

func TestMonotonicSeqUniqueness(t *testing.T) {
	storeDir, syncDir := setupTempEnv(t)
	a := emitOne(t, storeDir, syncDir, "first")
	b := emitOne(t, storeDir, syncDir, "second")
	if a.MonotonicSeq >= b.MonotonicSeq {
		t.Errorf("expected b.seq > a.seq, got %d %d", a.MonotonicSeq, b.MonotonicSeq)
	}
	got := readShard(t, syncDir, a.Host)
	if len(got) != 2 {
		t.Fatalf("expected 2 events on disk, got %d", len(got))
	}
}

func TestUTF8Sanitize(t *testing.T) {
	storeDir, _ := setupTempEnv(t)
	bad := string([]byte{0xff, 0xfe, 'a', 'b'})
	ev, err := event.New(storeDir, "note", "scope:test", bad)
	if err != nil {
		t.Fatal(err)
	}
	line, _, err := ev.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	var decoded event.Event
	if err := json.Unmarshal(line, &decoded); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !decoded.Truncated {
		t.Errorf("expected truncated=true after sanitize")
	}
}
