package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

func TestEmitBudgetRefillsPerWindow(t *testing.T) {
	b := newEmitBudget(3, 100*time.Millisecond)
	now := time.Now()
	for i := 0; i < 3; i++ {
		if !b.take(now) {
			t.Fatalf("token %d should be available", i)
		}
	}
	if b.take(now) {
		t.Error("budget exhausted, take must fail inside the window")
	}
	if !b.take(now.Add(150 * time.Millisecond)) {
		t.Error("budget must refill after the window")
	}
}

// A bulk rewrite must not fan out into one subprocess per file, and the events
// past the budget must stay visible as a rollup rather than vanish.
func TestWatchSourceCoalescesBulkChangeInsteadOfDropping(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "watch")
	if err := os.MkdirAll(watchDir, 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)

	src := Source{
		Name:    "bulk-src",
		Path:    watchDir,
		Pattern: "*.md",
		Op:      "create_or_modify",
		Emit:    Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	// One long window so the whole burst lands inside it.
	deb := newDebouncer(3 * time.Second)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watchSource(ctx, src, deb, shim) }()
	time.Sleep(200 * time.Millisecond)

	const files = maxEmitsPerWindow + 25
	for i := 0; i < files; i++ {
		p := filepath.Join(watchDir, fmt.Sprintf("f%03d.md", i))
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Long enough for the rollup ticker to fire at least once.
	time.Sleep(4500 * time.Millisecond)
	cancel()
	<-done

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("no emits at all: %v", err)
	}
	got := string(data)
	emits := strings.Count(got, "---")
	if emits > maxEmitsPerWindow+3 {
		t.Errorf("spawned %d emit subprocesses for %d files — budget not applied", emits, files)
	}
	if emits == 0 {
		t.Fatal("no emits recorded")
	}
	if !strings.Contains(got, "further changes coalesced") {
		t.Errorf("burst overflow was dropped silently instead of rolled up:\n%s", got)
	}
}

func TestRunEmitRollupReplacesPerFileSummary(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	dir := t.TempDir()
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)

	src := Source{
		Name: "roll", Path: dir, Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	req := emitReq{ev: fsnotify.Event{Name: dir, Op: fsnotify.Write}, coalesced: 42}
	if err := runEmit(context.Background(), shim, src, req); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(logPath)
	if !strings.Contains(string(data), "roll: 42 further changes coalesced") {
		t.Errorf("rollup summary missing: %q", string(data))
	}
}
