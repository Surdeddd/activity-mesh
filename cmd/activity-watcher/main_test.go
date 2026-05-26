package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

// ----- debounce -----

func TestDebouncerDeduplicatesWithinWindow(t *testing.T) {
	d := newDebouncer(100 * time.Millisecond)
	now := time.Now()
	if !d.hit(42, now) {
		t.Fatal("first call must pass")
	}
	if d.hit(42, now.Add(10*time.Millisecond)) {
		t.Fatal("dup inside window must be suppressed")
	}
	if d.hit(42, now.Add(11*time.Millisecond)) {
		t.Fatal("second dup inside window must be suppressed")
	}
}

func TestDebouncerLetsThroughAfterTTL(t *testing.T) {
	d := newDebouncer(50 * time.Millisecond)
	now := time.Now()
	if !d.hit(7, now) {
		t.Fatal("first")
	}
	if d.hit(7, now.Add(20*time.Millisecond)) {
		t.Fatal("dup suppressed")
	}
	if !d.hit(7, now.Add(60*time.Millisecond)) {
		t.Fatal("after window must pass")
	}
}

func TestDebouncerDistinctKeys(t *testing.T) {
	d := newDebouncer(time.Second)
	now := time.Now()
	if !d.hit(1, now) || !d.hit(2, now) {
		t.Fatal("distinct keys must each pass")
	}
}

// ----- hashKey -----

func TestHashKeyStableAndDistinct(t *testing.T) {
	a := hashKey("src", "/a")
	b := hashKey("src", "/a")
	if a != b {
		t.Fatal("same inputs must hash equal")
	}
	if hashKey("src", "/a") == hashKey("src", "/b") {
		t.Fatal("path must affect hash")
	}
	if hashKey("src1", "/a") == hashKey("src2", "/a") {
		t.Fatal("source name must affect hash")
	}
}

// ----- pattern matching -----

func TestMatchPatternBasename(t *testing.T) {
	cases := []struct {
		pattern string
		path    string
		want    bool
	}{
		{"*.md", "/x/y/foo.md", true},
		{"*.md", "/x/y/foo.txt", false},
		{"settings.json", "/x/.claude/settings.json", true},
		{"settings.json", "/x/.claude/settings.local.json", false},
		{"com.maxim.*.plist", "/Library/LaunchAgents/com.maxim.foo.plist", true},
		{"com.maxim.*.plist", "/Library/LaunchAgents/com.other.plist", false},
		{"*/SKILL.md", "/skills/myskill/SKILL.md", true},
		{"*/SKILL.md", "/skills/myskill/x/SKILL.md", true /* basename match still true */},
		{"**/*.md", "/wiki/foo/bar.md", true},
		{"**/*.md", "/wiki/foo/bar.txt", false},
		{"", "/anything", true},
	}
	for _, tc := range cases {
		got := matchPattern(tc.pattern, tc.path)
		if got != tc.want {
			t.Errorf("matchPattern(%q, %q) = %v, want %v", tc.pattern, tc.path, got, tc.want)
		}
	}
}

// ----- op matching -----

func TestMatchOp(t *testing.T) {
	create := fsnotify.Event{Op: fsnotify.Create}
	write := fsnotify.Event{Op: fsnotify.Write}
	rem := fsnotify.Event{Op: fsnotify.Remove}
	if !matchOp("create", create) || matchOp("create", write) {
		t.Error("create spec mismatch")
	}
	if !matchOp("modify", write) || matchOp("modify", create) {
		t.Error("modify spec mismatch")
	}
	if !matchOp("delete", rem) || matchOp("delete", create) {
		t.Error("delete spec mismatch")
	}
	if !matchOp("create_or_modify", create) || !matchOp("create_or_modify", write) {
		t.Error("create_or_modify spec mismatch")
	}
	if !matchOp("any", rem) || !matchOp("", create) {
		t.Error("any/empty must match")
	}
	if matchOp("create", rem) {
		t.Error("remove should not match create")
	}
}

// ----- template rendering -----

func TestRenderTemplate(t *testing.T) {
	out, err := renderTemplate("hi {{.Filename}} on {{.ParentDir}}", map[string]string{
		"Filename":  "x.md",
		"ParentDir": "wiki",
	})
	if err != nil {
		t.Fatal(err)
	}
	if out != "hi x.md on wiki" {
		t.Fatalf("got %q", out)
	}
}

func TestRenderTemplateEmpty(t *testing.T) {
	out, err := renderTemplate("", map[string]string{})
	if err != nil || out != "" {
		t.Fatalf("expected empty, got %q err=%v", out, err)
	}
}

func TestRenderTemplateBadParse(t *testing.T) {
	_, err := renderTemplate("{{.Bad", nil)
	if err == nil {
		t.Fatal("expected parse error")
	}
}

// ----- emitFacts -----

func TestEmitFacts(t *testing.T) {
	src := Source{Name: "foo"}
	ev := fsnotify.Event{Name: "/x/y/z.md", Op: fsnotify.Create}
	got := emitFacts(src, ev)
	if got["Filename"] != "z.md" {
		t.Errorf("Filename %q", got["Filename"])
	}
	if got["ParentDir"] != "y" {
		t.Errorf("ParentDir %q", got["ParentDir"])
	}
	if got["Source"] != "foo" {
		t.Errorf("Source %q", got["Source"])
	}
	if !strings.Contains(got["Op"], "CREATE") {
		t.Errorf("Op %q", got["Op"])
	}
}

// ----- expandHome -----

func TestExpandHome(t *testing.T) {
	h, _ := os.UserHomeDir()
	if got := expandHome("~/foo"); got != filepath.Join(h, "foo") {
		t.Errorf("got %q", got)
	}
	if got := expandHome("/abs/path"); got != "/abs/path" {
		t.Errorf("absolute path mangled: %q", got)
	}
}

// ----- YAML loader -----

func TestLoadConfigBasic(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "watcher.yaml")
	yaml := `
activity_log_bin: /tmp/activity-log
debounce_ms: 7500
sources:
  - name: skills
    path: /tmp/skills
    pattern: "*/SKILL.md"
    op: create
    recursive: true
    emit:
      kind: install
      scope: claude-mac
      summary_template: "installed {{.Filename}}"
      tags: [install, skill]

  - name: wiki
    path: /tmp/wiki
    pattern: "*.md"
    op: create_or_modify
    emit:
      kind: compile
      scope_template: "wiki:{{.ParentDir}}"
      priority: P2
`
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	// Pre-create the bin so resolveBin's existence check passes and the
	// value round-trips through fillDefaults unchanged (no PATH fallback).
	binPath := filepath.Join(dir, "activity-log")
	if err := os.WriteFile(binPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Patch yaml in place: swap /tmp/activity-log for the tmpdir path so the
	// test stays hermetic regardless of what's on the host's PATH.
	patched := strings.Replace(yaml, "/tmp/activity-log", binPath, 1)
	if err := os.WriteFile(cfgPath, []byte(patched), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	cfg.fillDefaults()
	if cfg.ActivityLogBin != binPath {
		t.Errorf("bin: %q (want %q)", cfg.ActivityLogBin, binPath)
	}
	if cfg.DebounceMs != 7500 || cfg.Debounce != 7500*time.Millisecond {
		t.Errorf("debounce ms=%d dur=%s", cfg.DebounceMs, cfg.Debounce)
	}
	if len(cfg.Sources) != 2 {
		t.Fatalf("expected 2 sources, got %d", len(cfg.Sources))
	}
	s := cfg.Sources[0]
	if s.Name != "skills" || s.Path != "/tmp/skills" || s.Pattern != "*/SKILL.md" {
		t.Errorf("source 0: %+v", s)
	}
	if !s.Recursive {
		t.Error("recursive flag lost")
	}
	if s.Emit.Kind != "install" || s.Emit.Scope != "claude-mac" {
		t.Errorf("emit: %+v", s.Emit)
	}
	if got := s.Emit.SummaryTemplate; !strings.Contains(got, "Filename") {
		t.Errorf("summary tmpl: %q", got)
	}
	if len(s.Emit.Tags) != 2 || s.Emit.Tags[0] != "install" || s.Emit.Tags[1] != "skill" {
		t.Errorf("tags: %v", s.Emit.Tags)
	}
	if cfg.Sources[1].Emit.ScopeTemplate == "" {
		t.Error("scope_template lost")
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "w.yaml")
	if err := os.WriteFile(p, []byte("sources:\n  - name: a\n    path: /tmp\n    emit:\n      kind: x\n      scope: y\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	cfg.fillDefaults()
	if cfg.Debounce != defaultDebounceWindow {
		t.Errorf("default debounce: %s", cfg.Debounce)
	}
	if cfg.ActivityLogBin != defaultActivityLog {
		t.Errorf("default bin: %s", cfg.ActivityLogBin)
	}
}

func TestLoadConfigComments(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "w.yaml")
	body := `
# top-level comment
debounce_ms: 100  # inline comment
sources:
  - name: a # source comment
    path: /tmp
    emit:
      kind: x
      scope: y
`
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DebounceMs != 100 {
		t.Errorf("debounce_ms: %d", cfg.DebounceMs)
	}
	if cfg.Sources[0].Name != "a" {
		t.Errorf("name: %q", cfg.Sources[0].Name)
	}
}

func TestLoadConfigUnknownKey(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "w.yaml")
	if err := os.WriteFile(p, []byte("bogus: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadConfig(p); err == nil {
		t.Fatal("expected unknown-key error")
	}
}

// ----- integration: spin up watcher + verify emit invocation -----

func TestWatchSourceCallsEmitOnCreate(t *testing.T) {
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
		Name:    "test-src",
		Path:    watchDir,
		Pattern: "*.md",
		Op:      "create",
		Emit: Emit{
			Kind:            "note",
			Scope:           "test",
			SummaryTemplate: "created {{.Filename}}",
		},
	}
	deb := newDebouncer(200 * time.Millisecond)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- watchSource(ctx, src, deb, shim)
	}()
	// give fsnotify time to subscribe
	time.Sleep(150 * time.Millisecond)

	target := filepath.Join(watchDir, "hello.md")
	if err := os.WriteFile(target, []byte("hi"), 0o644); err != nil {
		t.Fatal(err)
	}

	// debounce fires another write — must not double-emit.
	time.Sleep(50 * time.Millisecond)
	if err := os.WriteFile(target, []byte("hi2"), 0o644); err != nil {
		t.Fatal(err)
	}

	// poll for shim to record one emit
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(logPath); err == nil && len(data) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	cancel()
	<-done

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("emit log not written: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "--kind\nnote") {
		t.Errorf("kind missing: %q", got)
	}
	if !strings.Contains(got, "--scope\ntest") {
		t.Errorf("scope missing: %q", got)
	}
	if !strings.Contains(got, "created hello.md") {
		t.Errorf("summary missing: %q", got)
	}
	// debounce: must record exactly one invocation block (one trailing
	// separator line). Our shim writes one line per arg + a "---" terminator.
	count := strings.Count(got, "---")
	if count != 1 {
		t.Errorf("expected 1 emit, got %d (log:\n%s)", count, got)
	}
}

// TestDebouncerCollapsesOpVariants documents the macOS reality that a single
// os.WriteFile produces both CREATE and WRITE events. The debouncer keys on
// (source, path) only — so both ops collapse into one logical emit.
func TestDebouncerCollapsesOpVariants(t *testing.T) {
	d := newDebouncer(time.Second)
	now := time.Now()
	create := hashKey("src", "/x/foo.md")
	write := hashKey("src", "/x/foo.md")
	if create != write {
		t.Fatal("op-agnostic key broke")
	}
	if !d.hit(create, now) {
		t.Fatal("first event must pass")
	}
	if d.hit(write, now.Add(5*time.Millisecond)) {
		t.Fatal("op-variant follow-up must be suppressed")
	}
}

// writeEmitShim creates an executable that writes its argv to a log file —
// used to verify activity-watcher shells out with the correct flags without
// depending on a real activity-log binary.
func writeEmitShim(t *testing.T, dir, logPath string) string {
	t.Helper()
	shim := filepath.Join(dir, "emit-shim.sh")
	body := `#!/bin/sh
for a in "$@"; do
  printf '%s\n' "$a" >> "` + logPath + `"
done
printf '%s\n' '---' >> "` + logPath + `"
printf '01TESTID\n'
exit 0
`
	if err := os.WriteFile(shim, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	// sanity check: shell-callable
	if _, err := exec.LookPath("/bin/sh"); err != nil {
		t.Fatalf("sh missing: %v", err)
	}
	return shim
}
