package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/spf13/cobra"

	"github.com/Surdeddd/activity-mesh/pkg/event"
)

func compactCmd() *cobra.Command {
	var (
		keep    string
		dryRun  bool
		syncArg string
	)
	cmd := &cobra.Command{
		Use:   "compact",
		Short: "Archive events older than --keep from this host's shard into monthly .jsonl.gz files.",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			d, err := parseDuration(keep)
			if err != nil {
				return fmt.Errorf("--keep: %w", err)
			}
			if d <= 0 {
				return fmt.Errorf("--keep must be a positive duration, got %q", keep)
			}
			syncDirVal := cfg.SyncDir
			if syncArg != "" {
				if syncDirVal, err = normalizeDir(syncArg); err != nil {
					return err
				}
			}
			host := event.HostName()
			res, err := compactShard(compactOptions{
				shardPath:  filepath.Join(syncDirVal, "events-"+host+".jsonl"),
				archiveDir: filepath.Join(syncDirVal, "archive"),
				host:       host,
				storeDir:   cfg.StoreDir,
				cutoff:     time.Now().UTC().Add(-d),
				dryRun:     dryRun,
			})
			if err != nil {
				return err
			}
			if !dryRun {
				// A missing decay-state keeps the decay-daemon health check red
				// forever while compact keeps reporting success — say so out loud.
				if err := writeDecayState(); err != nil {
					fmt.Fprintf(os.Stderr, "warn: decay-state not updated: %v\n", err)
				}
			}
			printCompactSummary(os.Stdout, res)
			return nil
		},
	}
	cmd.Flags().StringVar(&keep, "keep", "90d", "retention window — events younger than this stay in the live shard (24h, 7d, 90d)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "report what would be archived without writing anything")
	cmd.Flags().StringVar(&syncArg, "sync-dir", "", "override sync directory (default from config)")
	return cmd
}

type compactOptions struct {
	shardPath  string    // live shard events-<host>.jsonl
	archiveDir string    // <sync>/archive
	host       string    // shard owner — must be THIS host (single-writer invariant)
	storeDir   string    // state dir holding seq-<host>; empty → skip locking
	cutoff     time.Time // events strictly older than this are archived
	dryRun     bool
}

type monthArchive struct {
	month string // "2026-01"
	file  string // archive file path
	count int
}

type compactResult struct {
	shard     string // shard base name, for the summary line
	missing   bool   // shard file does not exist
	dryRun    bool
	archived  int // event lines moved (or that would move) to archives
	kept      int // event lines remaining in the live shard
	malformed int // non-event lines preserved verbatim
	months    []monthArchive
}

func compactShard(o compactOptions) (*compactResult, error) {
	res := &compactResult{shard: filepath.Base(o.shardPath), dryRun: o.dryRun}
	if !o.dryRun && o.storeDir != "" {
		lock, err := event.AcquireHostLock(o.storeDir, o.host)
		if err != nil {
			return nil, fmt.Errorf("host lock: %w", err)
		}
		defer func() { _ = lock.Release() }()
	}
	data, err := os.ReadFile(o.shardPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			res.missing = true
			return res, nil
		}
		return nil, err
	}
	p := partitionShard(data, o.cutoff)
	res.archived, res.kept, res.malformed = p.archivedCount, p.keptEvents, p.malformed
	months := make([]string, 0, len(p.archive))
	for m := range p.archive {
		months = append(months, m)
	}
	sort.Strings(months)
	for _, m := range months {
		res.months = append(res.months, monthArchive{
			month: m,
			file:  filepath.Join(o.archiveDir, "events-"+o.host+"-"+m+".jsonl.gz"),
			count: len(p.archive[m]),
		})
	}
	if o.dryRun || res.archived == 0 {
		return res, nil
	}
	if err := os.MkdirAll(o.archiveDir, 0o755); err != nil {
		return nil, err
	}
	// Archives are append-only gzip members and the shard rewrite comes after
	// them, so any failure in between used to leave events in BOTH places: a
	// half-written member corrupting every later one, and the next run archiving
	// the same events again. Roll every touched archive back to its pre-run size.
	var touched []archiveState
	rollback := func() {
		for i := len(touched) - 1; i >= 0; i-- {
			a := touched[i]
			if !a.existed {
				_ = os.Remove(a.path)
				continue
			}
			_ = os.Truncate(a.path, a.size)
		}
	}
	for _, ma := range res.months {
		touched = append(touched, statArchive(ma.file))
		if err := appendGzipMember(ma.file, p.archive[ma.month]); err != nil {
			rollback()
			return nil, fmt.Errorf("archive %s: %w", ma.file, err)
		}
	}
	if d, err := os.Open(o.archiveDir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	if err := rewriteShard(o.shardPath, p.keep); err != nil {
		rollback()
		return nil, fmt.Errorf("rewrite shard: %w", err)
	}
	return res, nil
}

// archiveState is an archive file's size before this run appended to it.
type archiveState struct {
	path    string
	size    int64
	existed bool
}

func statArchive(path string) archiveState {
	fi, err := os.Stat(path)
	if err != nil {
		return archiveState{path: path}
	}
	return archiveState{path: path, size: fi.Size(), existed: true}
}

type partition struct {
	keep          []byte              // exact bytes of the rewritten live shard
	archive       map[string][][]byte // "YYYY-MM" → raw event lines (no trailing \n)
	keptEvents    int
	malformed     int
	archivedCount int
}

func partitionShard(data []byte, cutoff time.Time) *partition {
	p := &partition{archive: map[string][][]byte{}}
	var keep bytes.Buffer
	keep.Grow(len(data))
	rest := data
	for len(rest) > 0 {
		nl := bytes.IndexByte(rest, '\n')
		if nl < 0 {
			if len(bytes.TrimSpace(rest)) > 0 {
				if _, ok := lineTimestamp(rest); ok {
					p.keptEvents++
				} else {
					p.malformed++
				}
			}
			keep.Write(rest)
			break
		}
		line := rest[:nl]
		rest = rest[nl+1:]
		if len(bytes.TrimSpace(line)) == 0 {
			keep.Write(line)
			keep.WriteByte('\n')
			continue
		}
		ts, ok := lineTimestamp(line)
		switch {
		case !ok:
			p.malformed++
			keep.Write(line)
			keep.WriteByte('\n')
		case ts.Before(cutoff):
			m := ts.UTC().Format("2006-01")
			p.archive[m] = append(p.archive[m], line)
			p.archivedCount++
		default:
			p.keptEvents++
			keep.Write(line)
			keep.WriteByte('\n')
		}
	}
	p.keep = keep.Bytes()
	return p
}

func lineTimestamp(line []byte) (time.Time, bool) {
	var raw struct {
		TS string `json:"ts"`
	}
	if err := json.Unmarshal(line, &raw); err != nil || raw.TS == "" {
		return time.Time{}, false
	}
	t, err := event.ParseTS(raw.TS)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

func appendGzipMember(path string, lines [][]byte) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	for _, line := range lines {
		if _, err := gz.Write(line); err != nil {
			return err
		}
		if _, err := gz.Write([]byte{'\n'}); err != nil {
			return err
		}
	}
	if err := gz.Close(); err != nil {
		return err
	}
	return f.Sync()
}

func rewriteShard(shardPath string, content []byte) error {
	dir := filepath.Dir(shardPath)
	tmp, err := os.CreateTemp(dir, ".compact-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath) //nolint:errcheck — no-op after successful rename
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpPath, 0o644); err != nil { // CreateTemp gives 0600; shards are 0644
		return err
	}
	if err := os.Rename(tmpPath, shardPath); err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil { // dir fsync: not portable (Windows) — best effort
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func writeDecayState() error {
	dir := event.StateDir()
	if dir == "" {
		return errors.New("cannot resolve state dir (no $ACTIVITY_MESH_STATE and no home dir)")
	}
	path := filepath.Join(dir, "decay-state.json")
	payload := fmt.Sprintf(`{"last_run_ts":%d}`+"\n", time.Now().Unix())
	return atomicWriteFile(path, []byte(payload))
}

func printCompactSummary(w io.Writer, res *compactResult) {
	if res.missing {
		fmt.Fprintf(w, "%s: no shard for this host — nothing to compact\n", res.shard)
		return
	}
	verb := "archived"
	if res.dryRun {
		verb = "[dry-run] would archive"
	}
	fmt.Fprintf(w, "%s: %s %d, kept %d", res.shard, verb, res.archived, res.kept)
	if res.malformed > 0 {
		fmt.Fprintf(w, " (%d non-event lines preserved)", res.malformed)
	}
	fmt.Fprintln(w)
	for _, m := range res.months {
		fmt.Fprintf(w, "  %s  +%d\n", m.file, m.count)
	}
}
