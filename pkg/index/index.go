package index

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite"

	"github.com/Surdeddd/activity-mesh/pkg/event"
)

type Event struct {
	ULID     string         `json:"id"`
	TS       string         `json:"ts"`
	TSUnix   int64          `json:"ts_unix"`
	Host     string         `json:"host"`
	Agent    string         `json:"agent,omitempty"`
	Scope    string         `json:"scope,omitempty"`
	Kind     string         `json:"kind,omitempty"`
	Priority string         `json:"priority,omitempty"`
	Path     string         `json:"raw_jsonl_path,omitempty"`
	Offset   int64          `json:"raw_byte_offset,omitempty"`
	Payload  map[string]any `json:"payload"`
}

type QueryFilter struct {
	Since    time.Time
	Until    time.Time
	Agent    string
	Scope    string
	Kind     string
	Priority string
	Host     string
	ULID     string
	Limit    int
}

type Index struct {
	db *sql.DB // single-connection writer; serialises ingest
	// rdb is a separate read pool. The writer holds one connection for the whole
	// duration of a full rescan, so sharing it made every /recent and /search
	// queue behind the ingest — long past the daemon's 15s ReadTimeout on a
	// large shard. WAL gives readers a consistent snapshot without blocking.
	rdb     *sql.DB
	path    string
	mu      sync.Mutex
	cursors string
	// skipped counts shard lines dropped during ingest (unparseable ts) so the
	// divergence is visible in /metrics instead of silently shrinking the index.
	skipped atomic.Uint64
}

// SkippedLines reports how many shard lines this process refused to index.
func (i *Index) SkippedLines() uint64 { return i.skipped.Load() }

func NewIndex(dbPath string) (*Index, error) {
	if dbPath == "" {
		return nil, errors.New("dbPath required")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir: %w", err)
	}
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)", dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	idx := &Index{db: db, path: dbPath, cursors: filepath.Join(filepath.Dir(dbPath), "cursors.json")}
	if err := idx.ensureSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	if err := idx.reconcileWithCursors(); err != nil {
		_ = db.Close()
		return nil, err
	}
	// Opened after the schema exists so readers never race the initial CREATE.
	rdb, err := sql.Open("sqlite", dsn)
	if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("open sqlite (read pool): %w", err)
	}
	rdb.SetMaxOpenConns(4)
	if err := rdb.Ping(); err != nil {
		_ = rdb.Close()
		_ = db.Close()
		return nil, fmt.Errorf("ping (read pool): %w", err)
	}
	idx.rdb = rdb
	return idx, nil
}

// reconcileWithCursors repairs the two ways the DB and its sidecar state can
// disagree after an out-of-band repair (the runbook's "delete index.db and let
// it rebuild"): stale cursors that would skip every line of an empty DB, and an
// events_fts that lost its rows while events kept theirs.
func (i *Index) reconcileWithCursors() error {
	var events int64
	if err := i.db.QueryRow(`SELECT COUNT(*) FROM events`).Scan(&events); err != nil {
		return err
	}
	if events == 0 {
		// cursors.json outlived the DB — honouring it would resume mid-file and
		// leave the index permanently empty.
		c, err := i.loadCursors()
		if err == nil && len(c.Files) > 0 {
			if err := i.saveCursors(cursorFile{V: cursorVersion, Files: map[string]cursorEntry{}}); err != nil {
				return fmt.Errorf("reset stale cursors: %w", err)
			}
		}
		return nil
	}
	// Count via the docsize shadow table: text_content is trigger-computed and
	// absent from the content table, so any scan of events_fts itself errors.
	var fts int64
	if err := i.db.QueryRow(`SELECT COUNT(*) FROM events_fts_docsize`).Scan(&fts); err != nil {
		return err
	}
	if fts == 0 {
		// The FTS table was dropped/emptied while events survived, so /search
		// would answer 0 hits with no error. Repopulate explicitly: FTS5's own
		// 'rebuild' cannot be used here because text_content is a trigger-computed
		// column that does not exist on the content table.
		if _, err := i.db.Exec(ftsRepopulateSQL); err != nil {
			return fmt.Errorf("rebuild fts: %w", err)
		}
	}
	return nil
}

const ftsRepopulateSQL = `INSERT INTO events_fts(rowid, text_content)
SELECT id,
  COALESCE(json_extract(payload, '$.summary'), '') || ' ' ||
  COALESCE(agent, '') || ' ' || COALESCE(scope, '')
FROM events`

func (i *Index) Close() error {
	if i.rdb != nil {
		_ = i.rdb.Close()
	}
	return i.db.Close()
}

// reader returns the pool reads should use. Falls back to the writer when the
// read pool is not up yet (during NewIndex's own reconcile pass).
func (i *Index) reader() *sql.DB {
	if i.rdb != nil {
		return i.rdb
	}
	return i.db
}

func (i *Index) Path() string { return i.path }

const schemaSQL = `
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY,
  ulid TEXT NOT NULL UNIQUE,
  ts TEXT NOT NULL,
  ts_unix INTEGER NOT NULL,
  host TEXT NOT NULL,
  agent TEXT,
  scope TEXT,
  kind TEXT,
  priority TEXT,
  raw_jsonl_path TEXT NOT NULL,
  raw_byte_offset INTEGER NOT NULL,
  payload JSON NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ts ON events(ts_unix DESC);
CREATE INDEX IF NOT EXISTS idx_agent_ts ON events(agent, ts_unix DESC);
CREATE INDEX IF NOT EXISTS idx_scope_ts ON events(scope, ts_unix DESC);
CREATE INDEX IF NOT EXISTS idx_path ON events(raw_jsonl_path);
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
  text_content,
  content='events', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
  INSERT INTO events_fts(rowid, text_content)
  VALUES (new.id,
    COALESCE(json_extract(new.payload, '$.summary'), '') || ' ' ||
    COALESCE(new.agent, '') || ' ' || COALESCE(new.scope, ''));
END;
CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
  INSERT INTO events_fts(events_fts, rowid, text_content)
  VALUES ('delete', old.id,
    COALESCE(json_extract(old.payload, '$.summary'), '') || ' ' ||
    COALESCE(old.agent, '') || ' ' || COALESCE(old.scope, ''));
  INSERT INTO events_fts(rowid, text_content)
  VALUES (new.id,
    COALESCE(json_extract(new.payload, '$.summary'), '') || ' ' ||
    COALESCE(new.agent, '') || ' ' || COALESCE(new.scope, ''));
END;
CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
  INSERT INTO events_fts(events_fts, rowid, text_content)
  VALUES ('delete', old.id,
    COALESCE(json_extract(old.payload, '$.summary'), '') || ' ' ||
    COALESCE(old.agent, '') || ' ' || COALESCE(old.scope, ''));
END;
`

func (i *Index) ensureSchema() error {
	_, err := i.db.Exec(schemaSQL)
	if err != nil {
		return fmt.Errorf("schema: %w", err)
	}
	return nil
}

type Stats struct {
	TotalEvents     int64    `json:"total_events"`
	LastIndexedULID string   `json:"last_indexed_ulid"`
	Hosts           []string `json:"hosts"`
}

func (i *Index) Stats() (Stats, error) {
	var s Stats
	row := i.reader().QueryRow(`SELECT COUNT(*), COALESCE(MAX(ulid), '') FROM events`)
	if err := row.Scan(&s.TotalEvents, &s.LastIndexedULID); err != nil {
		return s, err
	}
	rows, err := i.reader().Query(`SELECT DISTINCT host FROM events ORDER BY host`)
	if err != nil {
		return s, err
	}
	defer rows.Close()
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			return s, err
		}
		s.Hosts = append(s.Hosts, h)
	}
	return s, rows.Err()
}

type cursorEntry struct {
	Offset int64  `json:"offset"`
	Prefix string `json:"prefix,omitempty"`
}

type cursorFile struct {
	V     int                    `json:"v"`
	Files map[string]cursorEntry `json:"files"`
}

const cursorVersion = 3

func (i *Index) loadCursors() (cursorFile, error) {
	empty := cursorFile{V: cursorVersion, Files: map[string]cursorEntry{}}
	buf, err := os.ReadFile(i.cursors)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return empty, nil
		}
		return empty, err
	}
	var c cursorFile
	if err := json.Unmarshal(buf, &c); err != nil || c.V != cursorVersion || c.Files == nil {
		return empty, nil
	}
	return c, nil
}

func (i *Index) saveCursors(c cursorFile) error {
	if err := os.MkdirAll(filepath.Dir(i.cursors), 0o755); err != nil {
		return err
	}
	tmp := i.cursors + ".tmp"
	buf, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, buf, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, i.cursors)
}

const upsertSQL = `INSERT INTO events
  (ulid, ts, ts_unix, host, agent, scope, kind, priority, raw_jsonl_path, raw_byte_offset, payload)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, json(?))
ON CONFLICT(ulid) DO UPDATE SET
  ts = excluded.ts,
  ts_unix = excluded.ts_unix,
  host = excluded.host,
  agent = excluded.agent,
  scope = excluded.scope,
  kind = excluded.kind,
  priority = excluded.priority,
  raw_jsonl_path = excluded.raw_jsonl_path,
  raw_byte_offset = excluded.raw_byte_offset,
  payload = excluded.payload
WHERE events.payload != excluded.payload
   OR events.raw_byte_offset != excluded.raw_byte_offset
   OR events.raw_jsonl_path != excluded.raw_jsonl_path`

func (i *Index) IngestJSONL(path string) (int, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	abs, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	cursors, err := i.loadCursors()
	if err != nil {
		return 0, err
	}
	f, err := os.Open(abs)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return 0, err
	}

	entry := cursors.Files[abs]
	startAt := entry.Offset
	hasher := sha256.New()
	if startAt > fi.Size() {
		startAt = 0
	} else if startAt > 0 {
		if _, err := io.CopyN(hasher, f, startAt); err != nil {
			return 0, err
		}
		if entry.Prefix != hex.EncodeToString(hasher.Sum(nil)) {
			startAt = 0
		}
	}
	fullScan := startAt == 0
	if fullScan {
		hasher.Reset()
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return 0, err
		}
	} else if startAt >= fi.Size() {
		return 0, nil
	}

	tx, err := i.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(upsertSQL)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()

	// Non-nil: a shard that drained to zero events must marshal to `[]`, not
	// `null` — `ulid NOT IN (SELECT value FROM json_each('null'))` is NULL for
	// every row, so the reconcile below would delete nothing and the index would
	// keep serving events `compact` already moved into the archive.
	seen := []string{}
	r := bufio.NewReaderSize(f, 256<<10)
	count, skipped, offset := 0, uint64(0), startAt
	for {
		line, rerr := r.ReadBytes('\n')
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return count, rerr
		}
		lineOffset := offset
		offset += int64(len(line))
		_, _ = hasher.Write(line)
		trimmed := strings.TrimSpace(string(bytes.TrimRight(line, "\n")))
		if trimmed == "" {
			continue
		}
		var raw map[string]any
		if err := json.Unmarshal([]byte(trimmed), &raw); err != nil {
			continue
		}
		ulid, _ := raw["id"].(string)
		ts, _ := raw["ts"].(string)
		host, _ := raw["host"].(string)
		if ulid == "" || ts == "" || host == "" {
			continue
		}
		tsUnix, terr := parseTimeUnix(ts)
		if terr != nil {
			// An unparseable ts would be indexed at epoch 0 and vanish from every
			// time-windowed query. Skip it like any other malformed line.
			skipped++
			continue
		}
		agent, _ := raw["agent"].(string)
		scope, _ := raw["scope"].(string)
		kind, _ := raw["kind"].(string)
		priority, _ := raw["priority"].(string)
		res, err := stmt.Exec(ulid, ts, tsUnix, host, agent, scope, kind, priority, abs, lineOffset, trimmed)
		if err != nil {
			return count, fmt.Errorf("upsert ulid=%s: %w", ulid, err)
		}
		if fullScan {
			seen = append(seen, ulid)
		}
		if n, err := res.RowsAffected(); err == nil && n > 0 {
			count++
		}
	}
	if fullScan {
		seenJSON, jerr := json.Marshal(seen)
		if jerr != nil {
			return count, jerr
		}
		if _, err := tx.Exec(
			`DELETE FROM events WHERE raw_jsonl_path = ? AND ulid NOT IN (SELECT value FROM json_each(?))`,
			abs, string(seenJSON)); err != nil {
			return count, fmt.Errorf("reconcile deletes: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return count, err
	}
	cursors.Files[abs] = cursorEntry{Offset: offset, Prefix: hex.EncodeToString(hasher.Sum(nil))}
	if err := i.saveCursors(cursors); err != nil {
		return count, fmt.Errorf("save cursors: %w", err)
	}
	i.skipped.Add(skipped)
	return count, nil
}

func (i *Index) IngestDir(syncDir string) (int, error) {
	absDir, err := filepath.Abs(syncDir)
	if err != nil {
		return 0, err
	}
	matches, err := filepath.Glob(filepath.Join(absDir, "events-*.jsonl"))
	if err != nil {
		return 0, err
	}
	total := 0
	known := map[string]bool{}
	for _, m := range matches {
		if abs, err := filepath.Abs(m); err == nil {
			known[abs] = true
		}
		n, err := i.IngestJSONL(m)
		if err != nil {
			return total, fmt.Errorf("ingest %s: %w", m, err)
		}
		total += n
	}

	i.mu.Lock()
	defer i.mu.Unlock()
	rows, err := i.db.Query(`SELECT DISTINCT raw_jsonl_path FROM events`)
	if err != nil {
		return total, fmt.Errorf("sweep: list indexed paths: %w", err)
	}
	var vanished []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			_ = rows.Close()
			return total, fmt.Errorf("sweep: scan path: %w", err)
		}
		// `known` is a snapshot of the glob taken before the ingest loop; a shard
		// created (and indexed by the watcher) since then is absent from it, so
		// confirm the file is really gone before dropping its rows.
		if filepath.Dir(p) == absDir && !known[p] && !fileExists(p) {
			vanished = append(vanished, p)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return total, fmt.Errorf("sweep: iterate paths: %w", err)
	}
	_ = rows.Close()
	for _, p := range vanished {
		if _, err := i.db.Exec(`DELETE FROM events WHERE raw_jsonl_path = ?`, p); err != nil {
			return total, fmt.Errorf("sweep: delete rows for %s: %w", p, err)
		}
	}

	cursors, err := i.loadCursors()
	if err != nil {
		return total, fmt.Errorf("sweep: load cursors: %w", err)
	}
	dirty := false
	for path := range cursors.Files {
		if filepath.Dir(path) == absDir && !known[path] && !fileExists(path) {
			delete(cursors.Files, path)
			dirty = true
		}
	}
	if dirty {
		if err := i.saveCursors(cursors); err != nil {
			return total, fmt.Errorf("sweep: save cursors: %w", err)
		}
	}
	return total, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (i *Index) Query(f QueryFilter) ([]Event, error) {
	return i.QueryContext(context.Background(), f)
}

func (i *Index) QueryContext(ctx context.Context, f QueryFilter) ([]Event, error) {
	var (
		sb   strings.Builder
		args []any
	)
	sb.WriteString(`SELECT ulid, ts, ts_unix, host, agent, scope, kind, priority, raw_jsonl_path, raw_byte_offset, payload FROM events WHERE 1=1`)
	if !f.Since.IsZero() {
		sb.WriteString(` AND ts_unix >= ?`)
		args = append(args, f.Since.Unix())
	}
	if !f.Until.IsZero() {
		sb.WriteString(` AND ts_unix <= ?`)
		args = append(args, f.Until.Unix())
	}
	if f.Agent != "" {
		sb.WriteString(` AND agent = ?`)
		args = append(args, f.Agent)
	}
	if f.Scope != "" {
		sb.WriteString(` AND scope = ?`)
		args = append(args, f.Scope)
	}
	if f.Kind != "" {
		sb.WriteString(` AND kind = ?`)
		args = append(args, f.Kind)
	}
	if f.Priority != "" {
		sb.WriteString(` AND priority = ?`)
		args = append(args, f.Priority)
	}
	if f.Host != "" {
		sb.WriteString(` AND host = ?`)
		args = append(args, f.Host)
	}
	if f.ULID != "" {
		sb.WriteString(` AND ulid = ?`)
		args = append(args, f.ULID)
	}
	sb.WriteString(` ORDER BY ts_unix DESC`)
	if f.Limit > 0 {
		sb.WriteString(` LIMIT ?`)
		args = append(args, f.Limit)
	}
	rows, err := i.reader().QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEvents(rows)
}

func (i *Index) Search(query string, since time.Time, limit int) ([]Event, error) {
	if strings.TrimSpace(query) == "" {
		return nil, errors.New("empty query")
	}
	if limit <= 0 {
		limit = 20
	}
	q := sanitizeFTS(query)
	args := []any{q}
	sb := strings.Builder{}
	sb.WriteString(`
SELECT e.ulid, e.ts, e.ts_unix, e.host, e.agent, e.scope, e.kind, e.priority, e.raw_jsonl_path, e.raw_byte_offset, e.payload
FROM events_fts
JOIN events e ON e.id = events_fts.rowid
WHERE events_fts MATCH ?`)
	if !since.IsZero() {
		sb.WriteString(` AND e.ts_unix >= ?`)
		args = append(args, since.Unix())
	}
	sb.WriteString(` ORDER BY bm25(events_fts) ASC LIMIT ?`)
	args = append(args, limit)
	rows, err := i.reader().Query(sb.String(), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEvents(rows)
}

func (i *Index) Aggregate(by, window string) (map[string]int, error) {
	col, ok := aggregateCol(by)
	if !ok {
		return nil, fmt.Errorf("unknown group_by %q", by)
	}
	since, until, err := windowRange(window)
	if err != nil {
		return nil, err
	}
	q := fmt.Sprintf(`SELECT COALESCE(%s,'(none)'), COUNT(*) FROM events WHERE ts_unix >= ?`, col)
	args := []any{since.Unix()}
	if !until.IsZero() {
		q += ` AND ts_unix < ?`
		args = append(args, until.Unix())
	}
	q += fmt.Sprintf(` GROUP BY %s ORDER BY 2 DESC`, col)
	rows, err := i.reader().Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		out[k] = n
	}
	return out, rows.Err()
}

func aggregateCol(by string) (string, bool) {
	switch by {
	case "scope", "agent", "kind", "host", "priority":
		return by, true
	}
	return "", false
}

func windowRange(window string) (time.Time, time.Time, error) {
	now := time.Now().UTC()
	midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	switch window {
	case "", "24h":
		return now.Add(-24 * time.Hour), time.Time{}, nil
	case "today":
		return midnight, time.Time{}, nil
	case "yesterday":
		return midnight.AddDate(0, 0, -1), midnight, nil
	case "7d":
		return now.Add(-7 * 24 * time.Hour), time.Time{}, nil
	}
	if t, err := time.Parse(time.RFC3339, window); err == nil {
		return t.UTC(), time.Time{}, nil
	}
	return time.Time{}, time.Time{}, fmt.Errorf("unknown window %q", window)
}

// parseTimeUnix shares the canonical layout list with emit/compact/query —
// a private copy here is how "ts" formats silently drift apart.
func parseTimeUnix(ts string) (int64, error) {
	t, err := event.ParseTS(ts)
	if err != nil {
		return 0, err
	}
	return t.Unix(), nil
}

func sanitizeFTS(q string) string {
	var parts []string
	for _, tok := range strings.Fields(q) {
		tok = strings.ReplaceAll(tok, `"`, "")
		tok = strings.ReplaceAll(tok, `\`, "")
		if tok == "" {
			continue
		}
		parts = append(parts, `"`+tok+`"`)
	}
	if len(parts) == 0 {
		return `""`
	}
	return strings.Join(parts, " ")
}

func scanEvents(rows *sql.Rows) ([]Event, error) {
	var out []Event
	for rows.Next() {
		var (
			e       Event
			payload string
		)
		if err := rows.Scan(&e.ULID, &e.TS, &e.TSUnix, &e.Host, &e.Agent, &e.Scope, &e.Kind, &e.Priority, &e.Path, &e.Offset, &payload); err != nil {
			return nil, err
		}
		var raw map[string]any
		if err := json.Unmarshal([]byte(payload), &raw); err == nil {
			e.Payload = raw
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
