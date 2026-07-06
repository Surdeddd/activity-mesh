// compact — shard compaction for this host's events-<host>.jsonl.
//
// Events older than --keep (default 90d) move, grouped by month, into
// <sync>/archive/events-<host>-YYYY-MM.jsonl.gz. If a monthly archive
// already exists the batch is appended as an additional gzip member —
// concatenated gzip members are a valid stream (RFC 1952 §2.2) readable by
// zcat and Go's multistream gzip.Reader. The live shard is then rewritten
// atomically (temp file in same dir + fsync + rename + best-effort dir
// fsync) while holding the same per-host exclusive flock emit uses
// (pkg/event.AcquireHostLock on seq-<host>).
//
// Daemon safety (pkg/index ingest semantics): the indexer keeps a per-file
// byte cursor (cursors.json) but dedupes by event id — events.ulid is
// UNIQUE and inserts are INSERT OR IGNORE. When the rewritten shard is
// smaller than a daemon's cursor, the cursor resets to 0 and the full file
// is rescanned with zero duplicates. Caveat: a daemon whose unread backlog
// exceeds the number of bytes removed keeps its stale cursor and can skip
// the not-yet-ingested tail; in practice fsnotify (200ms debounce) plus the
// 5-minute periodic ingest keep cursors current, and compaction only
// removes events older than --keep. Recovery is deleting cursors.json +
// index.db and letting the daemon rebuild.
//
// Malformed JSONL lines (bad JSON, missing/unparseable ts, blank, or a
// trailing line without newline — possibly an append in flight) are
// preserved verbatim in the live shard, never archived, never dropped.
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
				syncDirVal = syncArg
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

// compactShard runs the partition → archive → rewrite pipeline. Archives are
// written before the live shard is replaced: a crash in between leaves
// duplicates (deduped downstream by ULID), never data loss.
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
	for _, ma := range res.months {
		if err := appendGzipMember(ma.file, p.archive[ma.month]); err != nil {
			return nil, fmt.Errorf("archive %s: %w", ma.file, err)
		}
	}
	// Dir fsync so a newly created monthly archive survives a power cut that
	// happens after the shard rewrite below (best effort — not portable).
	if d, err := os.Open(o.archiveDir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	if err := rewriteShard(o.shardPath, p.keep); err != nil {
		return nil, fmt.Errorf("rewrite shard: %w", err)
	}
	return res, nil
}

type partition struct {
	keep          []byte              // exact bytes of the rewritten live shard
	archive       map[string][][]byte // "YYYY-MM" → raw event lines (no trailing \n)
	keptEvents    int
	malformed     int
	archivedCount int
}

// partitionShard splits raw shard bytes at cutoff. A line is archived only
// when it is a complete (newline-terminated) JSON object with a parseable ts
// older than cutoff; everything else — blank lines, malformed JSON, missing
// or invalid ts, and a partial trailing line without newline — is preserved
// byte-exact in the live shard.
func partitionShard(data []byte, cutoff time.Time) *partition {
	p := &partition{archive: map[string][][]byte{}}
	var keep bytes.Buffer
	keep.Grow(len(data))
	rest := data
	for len(rest) > 0 {
		nl := bytes.IndexByte(rest, '\n')
		if nl < 0 {
			// Trailing line without newline — possibly an emit in flight.
			// Always keep it (never archive an unterminated line).
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

// lineTimestamp extracts and parses the "ts" field through the canonical
// event.ParseTS layouts (shared with query and pkg/index).
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

// appendGzipMember appends lines (newline re-added) as one new gzip member
// to path, creating it if absent, then fsyncs. Concatenated members keep the
// archive zcat-readable without ever rewriting old data.
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

// rewriteShard atomically replaces shardPath with content: temp file in the
// same directory → fsync → rename → best-effort directory fsync. The temp
// name (.compact-*.tmp) deliberately misses the events-*.jsonl pattern the
// daemon's fsnotify watcher ingests.
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
