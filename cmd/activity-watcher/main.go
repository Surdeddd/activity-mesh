package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"text/template"
	"time"

	"github.com/fsnotify/fsnotify"
)

const (
	defaultDebounceWindow = 5 * time.Second
	defaultActivityLog    = "activity-log"
)

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

type Config struct {
	ActivityLogBin string        `yaml:"activity_log_bin"`
	DebounceMs     int           `yaml:"debounce_ms"`
	Debounce       time.Duration `yaml:"-"`
	Sources        []Source      `yaml:"sources"`
}

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

func resolveBin(p string) string {
	if p == "" {
		return p
	}
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

type debouncer struct {
	mu     sync.Mutex
	seen   map[uint64]time.Time
	window time.Duration
}

func newDebouncer(window time.Duration) *debouncer {
	return &debouncer{seen: make(map[uint64]time.Time), window: window}
}

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

// maxEmitsPerWindow bounds how many individual `activity-log emit` subprocesses
// one source may spawn per debounce window; the rest are coalesced.
const maxEmitsPerWindow = 20

// emitBudget is a per-source token bucket that refills once per window.
type emitBudget struct {
	size      int
	left      int
	window    time.Duration
	refilleAt time.Time
}

func newEmitBudget(size int, window time.Duration) *emitBudget {
	return &emitBudget{size: size, left: size, window: window}
}

func (b *emitBudget) take(now time.Time) bool {
	if b.refilleAt.IsZero() || now.Sub(b.refilleAt) >= b.window {
		b.left = b.size
		b.refilleAt = now
	}
	if b.left == 0 {
		return false
	}
	b.left--
	return true
}

// emitReq is one unit of work for the emit worker: either a filesystem event or
// a rollup standing in for a coalesced burst.
type emitReq struct {
	ev        fsnotify.Event
	coalesced int // > 0 marks a rollup
}

func hashKey(srcName, path string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(srcName))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(path))
	return h.Sum64()
}

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

func validOp(spec string) bool {
	switch strings.ToLower(strings.TrimSpace(spec)) {
	case "", "create_or_modify", "create", "modify", "delete", "any":
		return true
	}
	return false
}

func matchPattern(pattern, evPath string) bool {
	if pattern == "" {
		return true
	}
	if ok, _ := filepath.Match(pattern, filepath.Base(evPath)); ok {
		return true
	}
	if strings.HasPrefix(pattern, "**/") {
		if ok, _ := filepath.Match(strings.TrimPrefix(pattern, "**/"), filepath.Base(evPath)); ok {
			return true
		}
	}
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

func runEmit(ctx context.Context, bin string, src Source, req emitReq) error {
	ev := req.ev
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
	if req.coalesced > 0 {
		// The burst summary replaces the per-file one — the individual paths are
		// gone by construction, but the count is not.
		summary = fmt.Sprintf("%s: %d further changes coalesced", src.Name, req.coalesced)
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

// maxWatchDepth bounds the recursive walk so a pathological tree (or a symlink
// chain EvalSymlinks cannot collapse) can never spin forever.
const maxWatchDepth = 64

// addTree watches dir and every directory beneath it, following symlinked
// directories once each. Add failures are logged rather than dropped: silently
// half-watching a tree looks identical to "nothing changed".
func addTree(w *fsnotify.Watcher, root, srcName string) (added, failed int) {
	seen := map[string]bool{}
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if depth > maxWatchDepth {
			log.Printf("watch depth limit reached src=%q path=%q", srcName, dir)
			return
		}
		real, err := filepath.EvalSymlinks(dir)
		if err != nil {
			real = dir
		}
		if seen[real] {
			return
		}
		seen[real] = true
		if err := w.Add(dir); err != nil {
			log.Printf("watch add failed src=%q path=%q: %v", srcName, dir, err)
			failed++
			return
		}
		added++
		entries, err := os.ReadDir(dir)
		if err != nil {
			log.Printf("watch scan failed src=%q path=%q: %v", srcName, dir, err)
			failed++
			return
		}
		for _, e := range entries {
			if skipWatchDir(e.Name()) {
				continue
			}
			p := filepath.Join(dir, e.Name())
			// os.Stat (not e.IsDir) so symlinked directories are followed too.
			if fi, serr := os.Stat(p); serr == nil && fi.IsDir() {
				walk(p, depth+1)
			}
		}
	}
	walk(root, 0)
	return added, failed
}

func skipWatchDir(name string) bool {
	switch name {
	case "node_modules", ".git", ".hg", ".svn", "vendor",
		".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache",
		"dist", "build", "target", ".next", ".turbo", ".cache":
		return true
	}
	return false
}

func watchSource(ctx context.Context, src Source, deb *debouncer, bin string) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("new watcher: %w", err)
	}
	defer w.Close()

	info, err := os.Stat(src.Path)
	if err != nil {
		return fmt.Errorf("stat %q: %w", src.Path, err)
	}

	addRoot := src.Path
	effectivePattern := src.Pattern
	if !info.IsDir() {
		// A file path means "watch its directory"; without a pattern that would
		// silently emit an event for every sibling in that directory.
		addRoot = filepath.Dir(src.Path)
		if effectivePattern == "" {
			effectivePattern = filepath.Base(src.Path)
		}
	}
	src.Pattern = effectivePattern

	added, failed := 0, 0
	if src.Recursive && info.IsDir() {
		added, failed = addTree(w, addRoot, src.Name)
	} else if err := w.Add(addRoot); err != nil {
		return fmt.Errorf("watch %q: %w", addRoot, err)
	} else {
		added = 1
	}
	if added == 0 {
		return fmt.Errorf("watch %q: no directory could be watched (%d failures)", addRoot, failed)
	}
	log.Printf("source=%q watching=%q recursive=%v op=%q pattern=%q watched=%d failed=%d",
		src.Name, addRoot, src.Recursive, src.Op, effectivePattern, added, failed)

	emitCh := make(chan emitReq, 256)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for req := range emitCh {
			if err := runEmit(ctx, bin, src, req); err != nil {
				log.Printf("emit error src=%q path=%q: %v", src.Name, req.ev.Name, err)
			}
		}
	}()
	defer func() { close(emitCh); wg.Wait() }()

	// A bulk rewrite (a plugin update touching hundreds of files) used to fan
	// out into one `activity-log emit` subprocess per file — each taking the
	// host lock — and then silently drop everything past the queue. Spend a
	// bounded per-window budget on individual events and roll the rest up into
	// one event, so the burst stays visible without becoming a subprocess storm.
	budget := newEmitBudget(maxEmitsPerWindow, deb.window)
	var coalesced int
	rollup := time.NewTicker(deb.window)
	defer rollup.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil
		case ev, ok := <-w.Events:
			if !ok {
				return nil
			}
			// Re-watch BEFORE the filters: a new subdirectory never matches a file
			// pattern like "*.md", so filtering first made every recursive source
			// blind to any directory created after startup.
			isDir := false
			if ev.Op&fsnotify.Create != 0 {
				if fi, serr := os.Stat(ev.Name); serr == nil && fi.IsDir() {
					isDir = true
					if src.Recursive {
						addTree(w, ev.Name, src.Name)
					}
				}
			}
			if isDir {
				continue // directories are watch targets, never events themselves
			}
			if !matchOp(src.Op, ev) {
				continue
			}
			if !matchPattern(src.Pattern, ev.Name) {
				continue
			}
			key := hashKey(src.Name, ev.Name)
			now := time.Now()
			if !deb.hit(key, now) {
				continue
			}
			if !budget.take(now) {
				coalesced++
				continue
			}
			select {
			case emitCh <- emitReq{ev: ev}:
			default:
				coalesced++
			}
		case <-rollup.C:
			if coalesced == 0 {
				continue
			}
			n := coalesced
			coalesced = 0
			req := emitReq{ev: fsnotify.Event{Name: src.Path, Op: fsnotify.Write}, coalesced: n}
			select {
			case emitCh <- req:
				log.Printf("coalesced %d events src=%q", n, src.Name)
			default:
				log.Printf("emit queue full src=%q: %d events lost", src.Name, n)
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
	var failedSources atomic.Int64
	for _, src := range cfg.Sources {
		src := src
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := watchSource(ctx, src, deb, cfg.ActivityLogBin); err != nil {
				if !errors.Is(err, context.Canceled) {
					failedSources.Add(1)
					log.Printf("source %q ended: %v", src.Name, err)
				}
			}
		}()
	}
	wg.Wait()
	// Exiting 0 with every source dead reads as a clean shutdown to launchd and
	// systemd, so nothing ever restarts the watcher.
	if n := failedSources.Load(); n == int64(len(cfg.Sources)) {
		log.Fatalf("all %d sources failed to start — exiting non-zero so the supervisor restarts us", n)
	} else if n > 0 {
		log.Printf("activity-watcher shutdown: %d of %d sources had failed", n, len(cfg.Sources))
		return
	}
	log.Printf("activity-watcher shutdown clean")
}
