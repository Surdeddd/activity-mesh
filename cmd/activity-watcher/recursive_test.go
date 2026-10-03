package main

import (
	"context"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
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

type logTap struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (l *logTap) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *logTap) has(s string) bool {
	return l.count(s) > 0
}

func (l *logTap) count(s string) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Count(l.buf.String(), s)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func emitLogHas(logPath string, want []string) bool {
	data, err := os.ReadFile(logPath)
	if err != nil {
		return false
	}
	for _, s := range want {
		if !strings.Contains(string(data), s) {
			return false
		}
	}
	return true
}

func runSourceDuring(t *testing.T, src Source, bin, logPath string, act func(*logTap), want ...string) string {
	t.Helper()
	tap := &logTap{}
	prev := log.Writer()
	log.SetOutput(io.MultiWriter(prev, tap))
	defer log.SetOutput(prev)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watchSource(ctx, src, newDebouncer(200*time.Millisecond), bin) }()
	defer func() { cancel(); <-done }()
	waitFor(t, "the source to start watching", func() bool { return tap.has("watching=") })
	act(tap)
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) && !emitLogHas(logPath, want) {
		time.Sleep(50 * time.Millisecond)
	}
	data, _ := os.ReadFile(logPath)
	return string(data)
}

func shortRootPoll(t *testing.T) {
	old := rootPoll
	rootPoll = 50 * time.Millisecond
	t.Cleanup(func() { rootPoll = old })
}

func TestWatchSourceReportsFilesInsideAMovedInDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "skills")
	stage := filepath.Join(dir, "stage", "new-skill")
	for _, d := range []string{watchDir, stage} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(stage, "SKILL.md"), []byte("# skill"), 0o644); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "skills", Path: watchDir, Pattern: "*/SKILL.md", Op: "create_or_modify", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "installed {{.ParentDir}}"},
	}
	got := runSourceDuring(t, src, shim, logPath, func(*logTap) {
		if err := os.Rename(stage, filepath.Join(watchDir, "new-skill")); err != nil {
			t.Fatal(err)
		}
	}, "installed new-skill")
	if !strings.Contains(got, "installed new-skill") {
		t.Fatalf("a skill directory moved into a recursive source was never reported (emit log: %q)", got)
	}
}

func TestWatchSourceReattachesAReplacedRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	shortRootPoll(t)
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "notes")
	if err := os.MkdirAll(watchDir, 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "notes", Path: watchDir, Pattern: "*.md", Op: "create_or_modify",
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	got := runSourceDuring(t, src, shim, logPath, func(tap *logTap) {
		if err := os.Rename(watchDir, watchDir+".old"); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(watchDir, 0o755); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the replaced root to be re-attached", func() bool { return tap.has("re-attached") })
		if err := os.WriteFile(filepath.Join(watchDir, "after.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}, "changed after.md")
	if !strings.Contains(got, "changed after.md") {
		t.Fatalf("after the watched directory was replaced the source stayed silent forever (emit log: %q)", got)
	}
}

func TestWatchSourceHearsReusedNamesUnderAReplacedRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	shortRootPoll(t)
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "notes")
	if err := os.MkdirAll(filepath.Join(watchDir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	reused := []string{filepath.Join(watchDir, "a.md"), filepath.Join(watchDir, "sub", "b.md")}
	for _, p := range reused {
		if err := os.WriteFile(p, []byte("old"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	pathWithTrailingSlash := watchDir + string(filepath.Separator)
	src := Source{
		Name: "notes", Path: pathWithTrailingSlash, Pattern: "*.md", Op: "create_or_modify", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.ParentDir}}/{{.Filename}}"},
	}
	want := []string{"changed notes/a.md", "changed sub/b.md"}
	got := runSourceDuring(t, src, shim, logPath, func(tap *logTap) {
		if err := os.Rename(watchDir, watchDir+".old"); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(watchDir, "sub"), 0o755); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the replaced root to be re-attached", func() bool { return tap.has("re-attached") })
		for _, p := range reused {
			if err := os.WriteFile(p, []byte("new"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}, want...)
	for _, s := range want {
		if !strings.Contains(got, s) {
			t.Errorf("a file reusing a name from the replaced root went unreported: no %q (emit log: %q)", s, got)
		}
	}
}

func TestWatchSourceDoesNotReportASymlinkedDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "watch")
	target := filepath.Join(dir, "target")
	for _, d := range []string{watchDir, target} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(target, "inner.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "any-src", Path: watchDir, Pattern: "*", Op: "create_or_modify", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "touched {{.Filename}}"},
	}
	got := runSourceDuring(t, src, shim, logPath, func(*logTap) {
		if err := os.Symlink(target, filepath.Join(watchDir, "a-link")); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(watchDir, "z-sentinel.txt"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}, "touched z-sentinel.txt")
	if !strings.Contains(got, "touched z-sentinel.txt") {
		t.Fatalf("the sentinel file was never reported (emit log: %q)", got)
	}
	if strings.Contains(got, "a-link") {
		t.Fatalf("a symlinked directory was reported as a file: %q", got)
	}
}

func TestWatchSourceIgnoresASkippedDirectoryThatArrivesPopulated(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "project")
	stage := filepath.Join(dir, "stage", "node_modules")
	for _, d := range []string{watchDir, filepath.Join(stage, "pkg")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(stage, "pkg", "README.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "project", Path: watchDir, Pattern: "*.md", Op: "create", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "created {{.Filename}}"},
	}
	arrived := filepath.Join(watchDir, "node_modules")
	got := runSourceDuring(t, src, shim, logPath, func(*logTap) {
		if err := os.Rename(stage, arrived); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(watchDir, "z-first.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the first sentinel", func() bool { return emitLogHas(logPath, []string{"created z-first.md"}) })
		if err := os.WriteFile(filepath.Join(arrived, "pkg", "LATER.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(watchDir, "z-second.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}, "created z-second.md")
	if !strings.Contains(got, "created z-second.md") {
		t.Fatalf("the second sentinel was never reported (emit log: %q)", got)
	}
	if strings.Contains(got, "node_modules") {
		t.Fatalf("a skipped directory that arrived populated was announced or watched: %q", got)
	}
}

func TestWatchSourceAnnouncesWhatAReplacementRootArrivesWith(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	shortRootPoll(t)
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "notes")
	stage := filepath.Join(dir, "stage")
	for _, d := range []string{watchDir, filepath.Join(stage, "sub")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range []string{filepath.Join(stage, "top.md"), filepath.Join(stage, "sub", "deep.md")} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "notes", Path: watchDir, Pattern: "*.md", Op: "create_or_modify", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	want := []string{"changed top.md", "changed deep.md"}
	got := runSourceDuring(t, src, shim, logPath, func(*logTap) {
		if err := os.Rename(watchDir, watchDir+".old"); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(stage, watchDir); err != nil {
			t.Fatal(err)
		}
	}, want...)
	for _, s := range want {
		if !strings.Contains(got, s) {
			t.Errorf("a file the replacement root arrived with was never reported: no %q (emit log: %q)", s, got)
		}
	}
}

func TestWatchSourceDropsEditsInsideTheMovedAwayRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	shortRootPoll(t)
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "notes")
	if err := os.MkdirAll(filepath.Join(watchDir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(watchDir, "sub", "a.md"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "notes", Path: watchDir, Pattern: "*.md", Op: "create_or_modify", Recursive: true,
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	movedAway := watchDir + ".old"
	got := runSourceDuring(t, src, shim, logPath, func(tap *logTap) {
		if err := os.Rename(watchDir, movedAway); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(movedAway, "sub", "a.md"), []byte("edited"), 0o644); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the root to be reported gone", func() bool { return tap.has("went away") })
		if err := os.MkdirAll(watchDir, 0o755); err != nil {
			t.Fatal(err)
		}
		waitFor(t, "the replaced root to be re-attached", func() bool { return tap.has("re-attached") })
		if err := os.WriteFile(filepath.Join(watchDir, "z-sentinel.md"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}, "changed z-sentinel.md")
	if !strings.Contains(got, "changed z-sentinel.md") {
		t.Fatalf("the sentinel file was never reported (emit log: %q)", got)
	}
	if strings.Contains(got, "changed a.md") {
		t.Fatalf("an edit inside the moved-away root was reported under the root's path: %q", got)
	}
}

func TestWatchSourceLogsAnUnwatchableRootOnce(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	if os.Geteuid() == 0 {
		t.Skip("root bypasses the directory permissions this test relies on")
	}
	for _, tc := range []struct {
		name      string
		recursive bool
	}{{"flat", false}, {"recursive", true}} {
		t.Run(tc.name, func(t *testing.T) {
			shortRootPoll(t)
			dir := t.TempDir()
			watchDir := filepath.Join(dir, "notes")
			if err := os.MkdirAll(watchDir, 0o755); err != nil {
				t.Fatal(err)
			}
			logPath := filepath.Join(dir, "emit.log")
			shim := writeEmitShim(t, dir, logPath)
			src := Source{
				Name: "notes", Path: watchDir, Pattern: "*.md", Op: "create_or_modify", Recursive: tc.recursive,
				Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
			}
			failures := func(tap *logTap) int { return tap.count(`re-attach "`) + tap.count("watch add failed") }
			got := runSourceDuring(t, src, shim, logPath, func(tap *logTap) {
				if err := os.Rename(watchDir, watchDir+".old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(watchDir, 0o000); err != nil {
					t.Fatal(err)
				}
				waitFor(t, "a failed re-attach", func() bool { return failures(tap) > 0 })
				time.Sleep(10 * rootPoll)
				if err := os.Chmod(watchDir, 0o755); err != nil {
					t.Fatal(err)
				}
				waitFor(t, "the recovered root to be re-attached", func() bool { return tap.has("re-attached") })
				if n := failures(tap); n != 1 {
					t.Errorf("a root that could not be watched was logged %d times, want once until it recovers", n)
				}
				if err := os.WriteFile(filepath.Join(watchDir, "after.md"), []byte("x"), 0o644); err != nil {
					t.Fatal(err)
				}
			}, "changed after.md")
			if !strings.Contains(got, "changed after.md") {
				t.Fatalf("the recovered root was not watched (emit log: %q)", got)
			}
		})
	}
}

func TestWatchSourceReattachesARootReplacedTwice(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("integration uses POSIX shell shim")
	}
	shortRootPoll(t)
	dir := t.TempDir()
	watchDir := filepath.Join(dir, "notes")
	if err := os.MkdirAll(watchDir, 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(dir, "emit.log")
	shim := writeEmitShim(t, dir, logPath)
	src := Source{
		Name: "notes", Path: watchDir, Pattern: "*.md", Op: "create_or_modify",
		Emit: Emit{Kind: "note", Scope: "test", SummaryTemplate: "changed {{.Filename}}"},
	}
	rounds := []struct{ movedAway, file string }{{"notes.old1", "round1.md"}, {"notes.old2", "round2.md"}}
	got := runSourceDuring(t, src, shim, logPath, func(tap *logTap) {
		for i, r := range rounds {
			if err := os.Rename(watchDir, filepath.Join(dir, r.movedAway)); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(watchDir, 0o755); err != nil {
				t.Fatal(err)
			}
			waitFor(t, "the replaced root to be re-attached", func() bool { return tap.count("re-attached") == i+1 })
			if err := os.WriteFile(filepath.Join(watchDir, r.file), []byte("x"), 0o644); err != nil {
				t.Fatal(err)
			}
			waitFor(t, "the file in the re-attached root", func() bool { return emitLogHas(logPath, []string{"changed " + r.file}) })
		}
		time.Sleep(5 * rootPoll)
		if n := tap.count("re-attached"); n != len(rounds) {
			t.Errorf("re-attached %d times for %d replacements: the retry timer kept running after a successful re-attach", n, len(rounds))
		}
	}, "changed round1.md", "changed round2.md")
	for _, r := range rounds {
		if !strings.Contains(got, "changed "+r.file) {
			t.Errorf("round %s went unreported (emit log: %q)", r.file, got)
		}
	}
}
