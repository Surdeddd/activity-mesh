package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A recursive source must keep watching directories created after startup.
// Regression: the re-watch used to sit behind the pattern filter, so a new
// subdir (which never matches a file pattern like "*.md") was dropped before
// the watcher could add it — every file created under it stayed invisible.
func TestWatchSourceWatchesSubdirsCreatedAfterStart(t *testing.T) {
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
		Name:      "recursive-src",
		Path:      watchDir,
		Pattern:   "*.md",
		Op:        "create_or_modify",
		Recursive: true,
		Emit: Emit{
			Kind:            "note",
			Scope:           "test",
			SummaryTemplate: "created {{.Filename}}",
		},
	}
	deb := newDebouncer(200 * time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watchSource(ctx, src, deb, shim) }()
	time.Sleep(150 * time.Millisecond)

	// Nested creation: both levels must end up watched.
	sub := filepath.Join(watchDir, "outer", "inner")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)

	if err := os.WriteFile(filepath.Join(sub, "note.md"), []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Generous: the shim is a real subprocess, and cancel() below SIGKILLs an
	// emit still in flight. Under a loaded `go test ./...` a tight bound turns
	// that race into a flake. Success exits the loop immediately.
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(logPath); err == nil && strings.Contains(string(data), "---") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	cancel()
	<-done

	data, _ := os.ReadFile(logPath)
	if !strings.Contains(string(data), "created note.md") {
		t.Fatalf("no emit for a file in a subdir created after startup (log: %q)", string(data))
	}
}

// Directories must never be reported as events themselves — only the files
// inside them. Guards the fix above from over-correcting into dir emits.
func TestWatchSourceDoesNotEmitForDirectories(t *testing.T) {
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
		Name:      "any-src",
		Path:      watchDir,
		Pattern:   "*", // matches directories too
		Op:        "create_or_modify",
		Recursive: true,
		Emit: Emit{
			Kind:            "note",
			Scope:           "test",
			SummaryTemplate: "touched {{.Filename}}",
		},
	}
	deb := newDebouncer(200 * time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watchSource(ctx, src, deb, shim) }()
	time.Sleep(150 * time.Millisecond)

	if err := os.MkdirAll(filepath.Join(watchDir, "plaindir"), 0o755); err != nil {
		t.Fatal(err)
	}
	time.Sleep(600 * time.Millisecond)
	cancel()
	<-done

	data, _ := os.ReadFile(logPath)
	if strings.Contains(string(data), "plaindir") {
		t.Fatalf("emitted an event for a directory: %q", string(data))
	}
}
