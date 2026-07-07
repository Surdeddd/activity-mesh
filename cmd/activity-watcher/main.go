// Command activity-watcher is the cross-platform fswatch capture daemon for
// activity-mesh. It watches a configurable list of filesystem sources and on
// matching events shells out to the `activity-log` binary so the daemon stays
// thin (≤500 LOC, single external dep on fsnotify).
//
// Sources are declared in ~/.config/activity-mesh/watcher.yaml — one watch
// goroutine per source, all coordinated through a debounce ring buffer that
// suppresses duplicate (path, op) events within a 5s window.
//
// Logs to stderr. Graceful shutdown on SIGTERM/SIGINT. launchd/systemd-friendly.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"text/template"
	"time"

	"github.com/fsnotify/fsnotify"
)

const (
	defaultDebounceWindow = 5 * time.Second
	defaultActivityLog    = "activity-log"
)

// Source describes one watch entry from watcher.yaml.
type Source struct {
	Name            string `yaml:"name"`
	Path            string `yaml:"path"`
	Pattern         string `yaml:"pattern"`
	Op              string `yaml:"op"` // create | modify | delete | create_or_modify
	Recursive       bool   `yaml:"recursive"`
	DiffField       string `yaml:"diff_field"`
	Emit            Emit   `yaml:"emit"`
	SummaryTemplate string `yaml:"summary_template"`
}

// Emit describes the activity-log emit call to perform on match.
type Emit struct {
	Kind            string   `yaml:"kind"`
	KindTemplate    string   `yaml:"kind_template"`
	Scope           string   `yaml:"scope"`
	ScopeTemplate   string   `yaml:"scope_template"`
	Agent           string   `yaml:"agent"`
	Priority        string   `yaml:"priority"`
	Tags            []string `yaml:"tags"`
	SummaryTemplate string   `yaml:"summary_template"`
}

// Config is the full parsed watcher config.
type Config struct {
	ActivityLogBin string        `yaml:"activity_log_bin"`
	DebounceMs     int           `yaml:"debounce_ms"`
	Debounce       time.Duration `yaml:"-"`
	Sources        []Source      `yaml:"sources"`
}

// fillDefaults applies fallbacks + post-load tweaks.
func (c *Config) fillDefaults() {
	if c.ActivityLogBin == "" {
		c.ActivityLogBin = defaultActivityLog
	}
	c.ActivityLogBin = resolveBin(expandHome(c.ActivityLogBin))
	if c.DebounceMs > 0 {
		c.Debounce = time.Duration(c.DebounceMs) * time.Millisecond
	} else {
		c.Debounce = defaultDebounceWindow
	}
	for i := range c.Sources {
		c.Sources[i].Path = expandHome(c.Sources[i].Path)
		// inherit summary template at top-level into Emit if not set there.
		if c.Sources[i].Emit.SummaryTemplate == "" && c.Sources[i].SummaryTemplate != "" {
			c.Sources[i].Emit.SummaryTemplate = c.Sources[i].SummaryTemplate
		}
	}
}

func expandHome(p string) string {
	if strings.HasPrefix(p, "~/") {
		if h, err := os.UserHomeDir(); err == nil {
			return filepath.Join(h, p[2:])
		}
	}
	return p
}

// resolveBin returns the bin path to use for fork/exec. If the configured
// absolute path doesn't exist, fall back to a PATH lookup by basename so the
// daemon survives common cross-machine drift (e.g. binary installed to
// ~/.local/bin vs /usr/local/bin). The original path is kept as-is when it
// exists or when PATH lookup also fails — the actual exec will produce the
// real error in that case.
func resolveBin(p string) string {
	if p == "" {
		return p
	}
	// Bare name: let exec.LookPath via Go's stdlib handle PATH.
	if !strings.ContainsRune(p, filepath.Separator) {
		return p
	}
	if _, err := os.Stat(p); err == nil {
		return p
	}
	if alt, err := exec.LookPath(filepath.Base(p)); err == nil {
		log.Printf("activity_log_bin: configured %q missing, falling back to %q from PATH", p, alt)
		return alt
	}
	return p
}

// debouncer keeps a TTL-window dedup table keyed by uint64 hash.
type debouncer struct {
	mu     sync.Mutex
	seen   map[uint64]time.Time
	window time.Duration
}

func newDebouncer(window time.Duration) *debouncer {
	return &debouncer{seen: make(map[uint64]time.Time), window: window}
}

// hit returns true if this event should be processed; false if it's a dup
// inside the TTL window. Auto-prunes expired entries on each call (cheap; the
// table is bounded by event rate × window).
func (d *debouncer) hit(key uint64, now time.Time) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	for k, t := range d.seen {
		if now.Sub(t) > d.window {
			delete(d.seen, k)
		}
	}
	if t, ok := d.seen[key]; ok && now.Sub(t) <= d.window {
		return false
	}
	d.seen[key] = now
	return true
}

// hashKey returns a stable 64-bit fingerprint for (source, path).
//
// We deliberately do NOT include the op string: macOS fsnotify often emits
// CREATE+WRITE pairs for a single os.WriteFile, and other platforms have
// similar quirks. Treating any sequence of ops on the same path inside the
// debounce window as one logical event matches the human intuition the
// daemon is supposed to capture.
func hashKey(srcName, path string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(srcName))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(path))
	return h.Sum64()
}

// matchOp returns true if the fsnotify op is allowed by the source's op spec.
func matchOp(spec string, ev fsnotify.Event) bool {
	switch strings.ToLower(strings.TrimSpace(spec)) {
	case "", "create_or_modify":
		return ev.Op&(fsnotify.Create|fsnotify.Write) != 0
	case "create":
		return ev.Op&fsnotify.Create != 0
	case "modify":
		return ev.Op&fsnotify.Write != 0
	case "delete":
		return ev.Op&fsnotify.Remove != 0
	case "any":
		return true
	}
	return false
}

// validOp reports whether spec is a recognised op keyword. An unrecognised op
// silently matches nothing at runtime, so the config loader rejects it early.
func validOp(spec string) bool {
	switch strings.ToLower(strings.TrimSpace(spec)) {
	case "", "create_or_modify", "create", "modify", "delete", "any":
		return true
	}
	return false
}

// matchPattern checks the source pattern against the event path.
// Supports filepath.Match shell globs (with one extension: "**/" prefix
// indicating recursive matching, which we honor via filepath.Base fallback).
func matchPattern(pattern, evPath string) bool {
	if pattern == "" {
		return true
	}
	// Try full-path match first (e.g. "settings.json" full filename).
	if ok, _ := filepath.Match(pattern, filepath.Base(evPath)); ok {
		return true
	}
	if strings.HasPrefix(pattern, "**/") {
		if ok, _ := filepath.Match(strings.TrimPrefix(pattern, "**/"), filepath.Base(evPath)); ok {
			return true
		}
	}
	// "*/SKILL.md" style: match parent-dir/filename
	if strings.Contains(pattern, "/") {
		parts := strings.SplitN(pattern, "/", 2)
		if len(parts) == 2 {
			parent := filepath.Base(filepath.Dir(evPath))
			name := filepath.Base(evPath)
			if ok1, _ := filepath.Match(parts[0], parent); ok1 {
				if ok2, _ := filepath.Match(parts[1], name); ok2 {
					return true
				}
			}
		}
	}
	return false
}

// renderTemplate runs a text/template with a small fact map.
func renderTemplate(tmpl string, data map[string]string) (string, error) {
	if tmpl == "" {
		return "", nil
	}
	t, err := template.New("emit").Parse(tmpl)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	if err := t.Execute(&sb, data); err != nil {
		return "", err
	}
	return sb.String(), nil
}

// emitFacts builds the substitution dictionary for templates.
func emitFacts(src Source, ev fsnotify.Event) map[string]string {
	abs := ev.Name
	return map[string]string{
		"Source":    src.Name,
		"Path":      abs,
		"Filename":  filepath.Base(abs),
		"ParentDir": filepath.Base(filepath.Dir(abs)),
		"Op":        ev.Op.String(),
	}
}

// runEmit shells out to activity-log emit with the templated values.
func runEmit(ctx context.Context, bin string, src Source, ev fsnotify.Event) error {
	facts := emitFacts(src, ev)

	kind := src.Emit.Kind
	if src.Emit.KindTemplate != "" {
		v, err := renderTemplate(src.Emit.KindTemplate, facts)
		if err != nil {
			return fmt.Errorf("kind tmpl: %w", err)
		}
		kind = v
	}
	scope := src.Emit.Scope
	if src.Emit.ScopeTemplate != "" {
		v, err := renderTemplate(src.Emit.ScopeTemplate, facts)
		if err != nil {
			return fmt.Errorf("scope tmpl: %w", err)
		}
		scope = v
	}
	summary, err := renderTemplate(src.Emit.SummaryTemplate, facts)
	if err != nil {
		return fmt.Errorf("summary tmpl: %w", err)
	}
	if summary == "" {
		summary = fmt.Sprintf("%s: %s on %s", src.Name, ev.Op.String(), filepath.Base(ev.Name))
	}
	if kind == "" || scope == "" {
		return fmt.Errorf("kind/scope empty for source %q (kind=%q scope=%q)", src.Name, kind, scope)
	}

	args := []string{"emit", "--kind", kind, "--scope", scope, "--summary", summary}
	if src.Emit.Agent != "" {
		args = append(args, "--agent", src.Emit.Agent)
	}
	if src.Emit.Priority != "" {
		args = append(args, "--priority", src.Emit.Priority)
	}
	if len(src.Emit.Tags) > 0 {
		args = append(args, "--tags", strings.Join(src.Emit.Tags, ","))
	}
	args = append(args, "--ref", "file://"+ev.Name)

	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, bin, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("activity-log emit failed (%v): %s", err, strings.TrimSpace(string(out)))
	}
	log.Printf("emit ok src=%q kind=%s scope=%s id=%s", src.Name, kind, scope, strings.TrimSpace(string(out)))
	return nil
}

// watchSource runs one fsnotify watcher loop bound to a single Source.
// skipWatchDir reports dirs that explode the recursive watch/fd count without
// ever carrying a signal we emit on (dependency trees, VCS, build output,
// caches). macOS kqueue costs one fd per watched dir, so descending into a
// node_modules-heavy tree (e.g. ~/.openclaw/agents) can blow past
// kern.maxfilesperproc and wedge the watcher with "too many open files".
func skipWatchDir(name string) bool {
	switch name {
	case "node_modules", ".git", ".hg", ".svn", "vendor",
		".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache",
		"dist", "build", "target", ".next", ".turbo", ".cache":
		return true
	}
	return false
}

// Recursively walks the path on init to add subdirectories when src.Recursive.
func watchSource(ctx context.Context, src Source, deb *debouncer, bin string) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("new watcher: %w", err)
	}
	defer w.Close()

	// Normalise path: a missing dir is a config error worth reporting.
	info, err := os.Stat(src.Path)
	if err != nil {
		return fmt.Errorf("stat %q: %w", src.Path, err)
	}

	addRoot := src.Path
	if !info.IsDir() {
		addRoot = filepath.Dir(src.Path)
	}
	if err := w.Add(addRoot); err != nil {
		return fmt.Errorf("watch %q: %w", addRoot, err)
	}
	if src.Recursive && info.IsDir() {
		_ = filepath.WalkDir(addRoot, func(p string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if d.IsDir() && p != addRoot {
				if skipWatchDir(d.Name()) {
					return filepath.SkipDir
				}
				_ = w.Add(p)
			}
			return nil
		})
	}
	log.Printf("source=%q watching=%q recursive=%v op=%q pattern=%q", src.Name, addRoot, src.Recursive, src.Op, src.Pattern)

	// runEmit forks `activity-log emit` (up to 10s). Running it inline in the
	// select loop would stall event consumption and let fsnotify's internal
	// buffer overflow under a burst, silently dropping events. Hand emits to a
	// bounded worker so the loop keeps draining; if the worker falls far
	// behind, drop with a loud log rather than block (debounce already thins
	// most bursts).
	emitCh := make(chan fsnotify.Event, 256)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for ev := range emitCh {
			if err := runEmit(ctx, bin, src, ev); err != nil {
				log.Printf("emit error src=%q path=%q: %v", src.Name, ev.Name, err)
			}
		}
	}()
	defer func() { close(emitCh); wg.Wait() }()

	for {
		select {
		case <-ctx.Done():
			return nil
		case ev, ok := <-w.Events:
			if !ok {
				return nil
			}
			if !matchOp(src.Op, ev) {
				continue
			}
			if !matchPattern(src.Pattern, ev.Name) {
				continue
			}
			if src.Recursive && ev.Op&fsnotify.Create != 0 {
				if fi, err := os.Stat(ev.Name); err == nil && fi.IsDir() && !skipWatchDir(filepath.Base(ev.Name)) {
					_ = w.Add(ev.Name)
				}
			}
			key := hashKey(src.Name, ev.Name)
			if !deb.hit(key, time.Now()) {
				continue
			}
			select {
			case emitCh <- ev:
			default:
				log.Printf("emit queue full src=%q path=%q: dropping (worker behind)", src.Name, ev.Name)
			}
		case err, ok := <-w.Errors:
			if !ok {
				return nil
			}
			log.Printf("watcher error src=%q: %v", src.Name, err)
		}
	}
}

func defaultConfigPath() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".config", "activity-mesh", "watcher.yaml")
	}
	return "watcher.yaml"
}

func main() {
	cfgPath := flag.String("config", defaultConfigPath(), "path to watcher.yaml")
	checkOnly := flag.Bool("check", false, "validate config and exit")
	flag.Parse()

	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetOutput(os.Stderr)

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("load config %q: %v", *cfgPath, err)
	}
	cfg.fillDefaults()
	if len(cfg.Sources) == 0 {
		log.Fatalf("config has no sources")
	}
	if *checkOnly {
		fmt.Fprintf(os.Stderr, "config OK: %d sources, debounce=%s, bin=%s\n", len(cfg.Sources), cfg.Debounce, cfg.ActivityLogBin)
		return
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	log.Printf("activity-watcher starting: %d sources, debounce=%s, bin=%s", len(cfg.Sources), cfg.Debounce, cfg.ActivityLogBin)

	deb := newDebouncer(cfg.Debounce)
	var wg sync.WaitGroup
	for _, src := range cfg.Sources {
		src := src
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := watchSource(ctx, src, deb, cfg.ActivityLogBin); err != nil {
				if !errors.Is(err, context.Canceled) {
					log.Printf("source %q ended: %v", src.Name, err)
				}
			}
		}()
	}
	wg.Wait()
	log.Printf("activity-watcher shutdown clean")
}
