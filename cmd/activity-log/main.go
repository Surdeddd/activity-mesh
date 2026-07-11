package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/registry"
	"github.com/Surdeddd/activity-mesh/pkg/shard"
)

var version = "dev"

var configPath string

const (
	defaultSyncDir  = "Sync/activity"
	defaultStateDir = ".local/share/activity-mesh"
)

func main() {
	root := &cobra.Command{
		Use:           "activity-log",
		Short:         "Universal CLI for the activity-mesh shared activity log.",
		Version:       version,
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.PersistentFlags().StringVar(&configPath, "config", "", "override config file path")

	root.AddCommand(initCmd())
	root.AddCommand(emitCmd())
	root.AddCommand(queryCmd())
	root.AddCommand(statusCmd())
	root.AddCommand(compactCmd())
	root.AddCommand(clockSyncCmd())
	root.AddCommand(refreshScopesCmd())
	root.AddCommand(installGitHookCmd())
	root.AddCommand(redactCmd())
	root.AddCommand(redactShardCmd())

	if err := root.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

type config struct {
	SyncDir  string `json:"sync_dir"`
	StoreDir string `json:"store_dir"`
}

func defaultConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, defaultStateDir, "config.json"), nil
}

func loadConfig() (*config, error) {
	path := configPath
	if path == "" {
		p, err := defaultConfigPath()
		if err != nil {
			return nil, err
		}
		path = p
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("not initialised — run `activity-log init` first (looked at %s)", path)
		}
		return nil, err
	}
	var c config
	if err := json.Unmarshal(buf, &c); err != nil {
		return nil, fmt.Errorf("config json: %w", err)
	}
	if c.SyncDir == "" || c.StoreDir == "" {
		return nil, errors.New("config missing sync_dir / store_dir")
	}
	return &c, nil
}

func saveConfig(path string, c *config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	buf, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, buf, 0o644)
}

func initCmd() *cobra.Command {
	var customSync string
	var nonInteractive bool
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Bootstrap state dir, seq counter, and config.",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			storeDirVal := filepath.Join(home, defaultStateDir)
			if err := os.MkdirAll(storeDirVal, 0o755); err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Join(storeDirVal, "audit"), 0o700); err != nil {
				return err
			}

			syncDirVal := customSync
			if syncDirVal == "" {
				syncDirVal = filepath.Join(home, defaultSyncDir)
				if !nonInteractive && isTerminal(os.Stdin) {
					fmt.Printf("Sync directory [%s]: ", syncDirVal)
					reader := bufio.NewReader(os.Stdin)
					line, _ := reader.ReadString('\n')
					line = strings.TrimSpace(line)
					if line != "" {
						syncDirVal = line
					}
				}
			}
			if err := os.MkdirAll(syncDirVal, 0o755); err != nil {
				return fmt.Errorf("mkdir sync dir: %w", err)
			}
			if err := os.MkdirAll(filepath.Join(syncDirVal, ".staging"), 0o755); err != nil {
				return err
			}

			host, _ := os.Hostname()
			seqPath := filepath.Join(storeDirVal, "seq-"+strings.TrimSpace(host))
			if _, err := os.Stat(seqPath); errors.Is(err, os.ErrNotExist) {
				if err := os.WriteFile(seqPath, []byte("0\n"), 0o644); err != nil {
					return err
				}
			}

			cfgPath := configPath
			if cfgPath == "" {
				cfgPath = filepath.Join(storeDirVal, "config.json")
			}
			if err := saveConfig(cfgPath, &config{SyncDir: syncDirVal, StoreDir: storeDirVal}); err != nil {
				return err
			}
			fmt.Printf("activity-mesh initialised:\n  state: %s\n  sync : %s\n  config: %s\n", storeDirVal, syncDirVal, cfgPath)
			return nil
		},
	}
	cmd.Flags().StringVar(&customSync, "sync-dir", "", "override default sync directory (~/Sync/activity)")
	cmd.Flags().BoolVar(&nonInteractive, "yes", false, "accept defaults non-interactively")
	return cmd
}

func emitCmd() *cobra.Command {
	var (
		kind     string
		scope    string
		summary  string
		ref      string
		priority string
		tags     []string
		agent    string
	)
	cmd := &cobra.Command{
		Use:   "emit",
		Short: "Append a redacted event to the per-host JSONL shard.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if kind == "" || scope == "" || summary == "" {
				return errors.New("--kind, --scope, --summary required")
			}
			if !event.ValidPriority(priority) {
				return fmt.Errorf("invalid --priority %q (want P0..P3)", priority)
			}
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			if err := enforceRegistry(cfg.SyncDir, kind, scope); err != nil {
				return err
			}
			summary, truncated := event.NormalizeSummary(summary)
			if truncated {
				fmt.Fprintf(os.Stderr, "warn: summary truncated to %d chars (truncated=true recorded)\n", event.MaxSummaryRunes)
			}
			opts := []event.Option{}
			if ref != "" {
				opts = append(opts, event.WithRef(ref))
			}
			if priority != "" {
				opts = append(opts, event.WithPriority(priority))
			}
			if len(tags) > 0 {
				opts = append(opts, event.WithTags(tags))
			}
			if agent != "" {
				opts = append(opts, event.WithAgent(agent))
			}
			lock, err := event.AcquireHostLock(cfg.StoreDir, event.HostName())
			if err != nil {
				return err
			}
			defer lock.Release() //nolint:errcheck
			ev, err := event.NewLocked(lock, kind, scope, summary, opts...)
			if err != nil {
				return err
			}
			if truncated {
				ev.Truncated = true
			}
			line, hits, err := ev.Marshal()
			if err != nil {
				return err
			}
			if err := shard.AppendLocked(cfg.SyncDir, ev.Host, line); err != nil {
				return err
			}
			if err := event.AppendAudit(cfg.StoreDir, ev.ID, hits); err != nil {
				fmt.Fprintf(os.Stderr, "warn: audit append failed: %v\n", err)
			}
			fmt.Println(ev.ID)
			return nil
		},
	}
	cmd.Flags().StringVar(&kind, "kind", "", "event kind (decision|note|task|...)")
	cmd.Flags().StringVar(&scope, "scope", "", "scope tag (project:foo, infra:macbook, ...)")
	cmd.Flags().StringVar(&summary, "summary", "", "event summary (≤500 chars, redacted)")
	cmd.Flags().StringVar(&ref, "ref", "", "optional reference (wiki://, git://, file://)")
	cmd.Flags().StringVar(&priority, "priority", "", "P0|P1|P2|P3")
	cmd.Flags().StringSliceVar(&tags, "tags", nil, "comma-separated tags")
	cmd.Flags().StringVar(&agent, "agent", "", "override default agent label")
	return cmd
}

func enforceRegistry(syncDir, kind, scope string) error {
	if buf, err := os.ReadFile(filepath.Join(syncDir, "kinds.yaml")); err == nil {
		reg, lerr := registry.LoadFromBytes(buf, nil, nil, nil)
		if lerr != nil {
			fmt.Fprintf(os.Stderr, "warn: kinds.yaml unreadable (%v) — kind not validated\n", lerr)
		} else if !reg.IsValidKind(kind) && !strings.Contains(kind, "/") {
			return fmt.Errorf("kind %q is not in the kinds registry (namespaced org/name extensions are always allowed)", kind)
		}
	}
	if buf, err := os.ReadFile(filepath.Join(syncDir, "scopes.yaml")); err == nil {
		reg, lerr := registry.LoadFromBytes(nil, buf, nil, nil)
		if lerr != nil {
			fmt.Fprintf(os.Stderr, "warn: scopes.yaml unreadable (%v) — scope not validated\n", lerr)
		} else {
			allowed, warnMsg := reg.CanEmitToScope(scope)
			if !allowed {
				return fmt.Errorf("scope %q refuses new events: %s", scope, warnMsg)
			}
			if warnMsg != "" {
				fmt.Fprintf(os.Stderr, "warn: %s\n", warnMsg)
			}
		}
	}
	return nil
}

func queryCmd() *cobra.Command {
	var (
		since        string
		scope        string
		agent        string
		kind         string
		excludeKinds []string
		host         string
		limit        int
		format       string
	)
	cmd := &cobra.Command{
		Use:   "query",
		Short: "Read JSONL shards, filter, sort by ts ascending.",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			cutoff := time.Time{}
			if since != "" {
				d, perr := parseDuration(since)
				if perr != nil {
					return perr
				}
				cutoff = time.Now().UTC().Add(-d)
			}
			events, err := readEvents(cfg.SyncDir)
			if err != nil {
				return err
			}
			excluded := map[string]bool{}
			for _, k := range excludeKinds {
				excluded[k] = true
			}
			var filtered []event.Event
			for _, e := range events {
				if !cutoff.IsZero() {
					ts, perr := event.ParseTS(e.TS)
					if perr != nil || ts.Before(cutoff) {
						continue
					}
				}
				if scope != "" && e.Scope != scope {
					continue
				}
				if agent != "" && e.Agent != agent {
					continue
				}
				if kind != "" && e.Kind != kind {
					continue
				}
				if excluded[e.Kind] {
					continue
				}
				if host != "" && e.Host != host {
					continue
				}
				filtered = append(filtered, e)
			}
			sort.SliceStable(filtered, func(i, j int) bool {
				if filtered[i].TS == filtered[j].TS {
					return filtered[i].MonotonicSeq < filtered[j].MonotonicSeq
				}
				return filtered[i].TS < filtered[j].TS
			})
			if limit > 0 && len(filtered) > limit {
				filtered = filtered[len(filtered)-limit:]
			}
			return writeQuery(filtered, format)
		},
	}
	cmd.Flags().StringVar(&since, "since", "24h", "duration window (24h, 7d, 60m)")
	cmd.Flags().StringVar(&scope, "scope", "", "filter by scope")
	cmd.Flags().StringVar(&agent, "agent", "", "filter by agent")
	cmd.Flags().StringVar(&kind, "kind", "", "filter by kind")
	cmd.Flags().StringSliceVar(&excludeKinds, "exclude-kind", nil, "drop events of these kinds (repeatable / comma-separated)")
	cmd.Flags().StringVar(&host, "host", "", "filter by host")
	cmd.Flags().IntVar(&limit, "limit", 20, "limit (0 = no limit)")
	cmd.Flags().StringVar(&format, "format", "text", "text|json")
	return cmd
}

func parseDuration(s string) (time.Duration, error) {
	if strings.HasSuffix(s, "d") {
		n, err := time.ParseDuration(strings.TrimSuffix(s, "d") + "h")
		if err != nil {
			return 0, err
		}
		return n * 24, nil
	}
	return time.ParseDuration(s)
}

func readEvents(syncDir string) ([]event.Event, error) {
	matches, err := filepath.Glob(filepath.Join(syncDir, "events-*.jsonl"))
	if err != nil {
		return nil, err
	}
	var events []event.Event
	for _, p := range matches {
		f, err := os.Open(p)
		if err != nil {
			return nil, err
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 8<<20)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			var e event.Event
			if err := json.Unmarshal([]byte(line), &e); err != nil {
				continue // skip malformed line, don't abort whole query
			}
			events = append(events, e)
		}
		f.Close()
		if err := sc.Err(); err != nil {
			return nil, err
		}
	}
	return events, nil
}

func writeQuery(events []event.Event, format string) error {
	switch format {
	case "json":
		enc := json.NewEncoder(os.Stdout)
		for _, e := range events {
			if err := enc.Encode(e); err != nil {
				return err
			}
		}
		return nil
	case "text", "":
		w := bufio.NewWriter(os.Stdout)
		defer w.Flush()
		for _, e := range events {
			fmt.Fprintf(w, "%s [%s/%s] %s — %s\n", e.TS, e.Host, e.Agent, e.Kind, e.Summary)
		}
		return nil
	default:
		return fmt.Errorf("unknown format %q", format)
	}
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show last event per host + drift indicators.",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			matches, err := filepath.Glob(filepath.Join(cfg.SyncDir, "events-*.jsonl"))
			if err != nil {
				return err
			}
			if len(matches) == 0 {
				fmt.Println("no per-host shards yet")
				return nil
			}
			now := time.Now().UTC()
			for _, p := range matches {
				host := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(p), "events-"), ".jsonl")
				last, count, err := lastEvent(p)
				if err != nil {
					fmt.Printf("%s: error: %v\n", host, err)
					continue
				}
				if last == nil {
					fmt.Printf("%s: empty\n", host)
					continue
				}
				ts, _ := event.ParseTS(last.TS)
				age := now.Sub(ts)
				marker := ""
				if age > 24*time.Hour {
					marker = " (stale >24h!)"
				}
				fmt.Printf("%s: %d events, last %s — %s/%s%s\n", host, count, last.TS, last.Kind, last.Scope, marker)
			}
			return nil
		},
	}
}

func lastEvent(path string) (*event.Event, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	var last *event.Event
	count := 0
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var e event.Event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			continue
		}
		count++
		dup := e
		last = &dup
	}
	return last, count, sc.Err()
}

const clockSyncTimeout = 3 * time.Second

var defaultNTPServers = []string{
	"time.google.com:123",
	"time.cloudflare.com:123",
	"time.apple.com:123",
	"pool.ntp.org:123",
}

func clockSyncCmd() *cobra.Command {
	var server string
	cmd := &cobra.Command{
		Use:   "clock-sync",
		Short: "Measure local clock offset via SNTP and cache it for emitters.",
		Long: "Performs an SNTP query (UDP, 3s timeout per server) and atomically\n" +
			"writes the rounded offset (local−true, ms) to <state>/clock-offset-ms,\n" +
			"where emitters pick it up as the optional clock_offset_ms field.\n" +
			"Without --server it tries several providers in order (resilient to\n" +
			"networks that block a given one). On total failure the previous\n" +
			"cached value is left untouched.",
		RunE: func(cmd *cobra.Command, args []string) error {
			path := event.ClockOffsetPath()
			if path == "" {
				return errors.New("cannot resolve state dir (no $ACTIVITY_MESH_STATE and no home dir)")
			}
			servers := defaultNTPServers
			if server != "" {
				servers = []string{server}
			}
			offset, used, err := measureClockOffsetMulti(servers, clockSyncTimeout)
			if err != nil {
				return fmt.Errorf("clock-sync failed on all servers (%v): %w (cached offset left untouched)", servers, err)
			}
			ms := offset.Round(time.Millisecond).Milliseconds()
			if err := atomicWriteFile(path, []byte(strconv.FormatInt(ms, 10)+"\n")); err != nil {
				return fmt.Errorf("write %s: %w", path, err)
			}
			fmt.Printf("clock offset %+dms (local−true, via %s) → %s\n", ms, used, path)
			return nil
		},
	}
	cmd.Flags().StringVar(&server, "server", "", "NTP server host:port (default: try several providers)")
	return cmd
}

func measureClockOffsetMulti(servers []string, timeout time.Duration) (time.Duration, string, error) {
	var lastErr error
	for _, s := range servers {
		off, err := measureClockOffset(s, timeout)
		if err == nil {
			return off, s, nil
		}
		lastErr = err
	}
	return 0, "", lastErr
}

func atomicWriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) //nolint:errcheck — noop after successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}
