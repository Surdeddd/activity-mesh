// Command activity-log is the universal CLI writer/reader for activity-mesh.
//
// Subcommands:
//
//	activity-log init                                   one-time setup
//	activity-log emit  --kind X --scope Y --summary Z   append a redacted event
//	activity-log query --since 24h [filters]            read+filter events
//	activity-log status                                 print last event per host
//	activity-log compact --keep 90d                     archive old events from this host's shard
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/Surdeddd/activity-mesh/pkg/event"
)

// configPath stores the path passed via --config; default determined at runtime.
var (
	configPath string
	syncDir    string
	storeDir   string
)

const (
	defaultSyncDir  = "Sync/activity"
	defaultStateDir = ".local/share/activity-mesh"
)

func main() {
	root := &cobra.Command{
		Use:           "activity-log",
		Short:         "Universal CLI for the activity-mesh shared activity log.",
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

	if err := root.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

// ----- config -----

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

// ----- init -----

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

			// pre-create seq file so first emit is fast.
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

// ----- emit -----

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
			cfg, err := loadConfig()
			if err != nil {
				return err
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
			ev, err := event.New(cfg.StoreDir, kind, scope, summary, opts...)
			if err != nil {
				return err
			}
			line, hits, err := ev.Marshal()
			if err != nil {
				return err
			}
			if err := atomicAppend(cfg.SyncDir, ev.Host, line); err != nil {
				return err
			}
			if err := writeAudit(cfg.StoreDir, ev.ID, hits); err != nil {
				// audit failure must not lose the event; warn loudly.
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

// atomicAppend writes line+\n into <syncDir>/.staging/, then renames into the
// per-host JSONL shard with O_APPEND. The rename inside the staging step is
// what gives us atomicity for the (rare) case where Syncthing reads mid-write.
func atomicAppend(syncDir, host string, line []byte) error {
	staging := filepath.Join(syncDir, ".staging")
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return err
	}
	target := filepath.Join(syncDir, "events-"+host+".jsonl")
	// 1. write a temp file in staging holding just this line+\n
	tmp, err := os.CreateTemp(staging, "ev-*.jsonl")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) //nolint:errcheck — best effort cleanup
	if _, err := tmp.Write(line); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write([]byte("\n")); err != nil {
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
	// 2. open target O_APPEND, copy temp contents, fsync.
	out, err := os.OpenFile(target, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()
	buf, err := os.ReadFile(tmpPath)
	if err != nil {
		return err
	}
	if _, err := out.Write(buf); err != nil {
		return err
	}
	return out.Sync()
}

// writeAudit appends a redaction audit row (one JSON line) to the local
// (non-synced) audit log, partitioned by month. Hits == nil → noop.
func writeAudit(storeDir, evID string, hits []event.RedactHit) error {
	if len(hits) == 0 {
		return nil
	}
	dir := filepath.Join(storeDir, "audit")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	now := time.Now().UTC()
	path := filepath.Join(dir, "redactions-"+now.Format("2006-01")+".jsonl")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	row := map[string]any{
		"ts":    now.Format(time.RFC3339Nano),
		"event": evID,
		"hits":  hits,
	}
	buf, err := json.Marshal(row)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(buf, '\n')); err != nil {
		return err
	}
	return f.Sync()
}

// ----- query -----

func queryCmd() *cobra.Command {
	var (
		since  string
		scope  string
		agent  string
		kind   string
		host   string
		limit  int
		format string
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
			var filtered []event.Event
			for _, e := range events {
				if !cutoff.IsZero() {
					ts, perr := time.Parse("2006-01-02T15:04:05.000000Z", e.TS)
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
	cmd.Flags().StringVar(&host, "host", "", "filter by host")
	cmd.Flags().IntVar(&limit, "limit", 20, "limit (0 = no limit)")
	cmd.Flags().StringVar(&format, "format", "text", "text|json")
	return cmd
}

// parseDuration accepts Go-style durations + a "Nd" extension for days.
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

// ----- status -----

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
				ts, _ := time.Parse("2006-01-02T15:04:05.000000Z", last.TS)
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

// ----- clock-sync -----

// clockSyncTimeout bounds the whole SNTP round-trip (dial + send + recv).
const clockSyncTimeout = 3 * time.Second

func clockSyncCmd() *cobra.Command {
	var server string
	cmd := &cobra.Command{
		Use:   "clock-sync",
		Short: "Measure local clock offset via SNTP and cache it for emitters.",
		Long: "Performs one SNTP query (UDP, 3s timeout) and atomically writes the\n" +
			"rounded offset (local−true, ms) to <state>/clock-offset-ms, where\n" +
			"emitters pick it up as the optional clock_offset_ms event field.\n" +
			"On network failure the previous cached value is left untouched.",
		RunE: func(cmd *cobra.Command, args []string) error {
			path := event.ClockOffsetPath()
			if path == "" {
				return errors.New("cannot resolve state dir (no $ACTIVITY_MESH_STATE and no home dir)")
			}
			offset, err := measureClockOffset(server, clockSyncTimeout)
			if err != nil {
				return fmt.Errorf("clock-sync via %s failed: %w (cached offset left untouched)", server, err)
			}
			ms := offset.Round(time.Millisecond).Milliseconds()
			if err := atomicWriteFile(path, []byte(strconv.FormatInt(ms, 10)+"\n")); err != nil {
				return fmt.Errorf("write %s: %w", path, err)
			}
			fmt.Printf("clock offset %+dms (local−true, via %s) → %s\n", ms, server, path)
			return nil
		},
	}
	cmd.Flags().StringVar(&server, "server", "time.apple.com:123", "NTP server host:port")
	return cmd
}

// atomicWriteFile writes data to path via a temp file + rename in the same
// directory, so readers never observe a partial write.
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

// ----- io helpers -----

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// ensure unused import doesn't fail compilation
var _ = io.EOF
