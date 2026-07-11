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
