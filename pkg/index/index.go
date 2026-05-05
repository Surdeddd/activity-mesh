// Package index implements the SQLite + FTS5 indexer for activity-mesh.
//
// One Index instance = one SQLite database file (default
// ~/.local/share/activity-mesh/index.db) holding the events table, BM25 FTS5
// virtual table, and per-source byte-offset cursors used for incremental
// ingest of the per-host JSONL shards under ~/Sync/activity/.
//
// Concurrency: all public methods are safe for concurrent use; writes are
// serialised via a process-wide mutex while reads use SQLite's WAL.
package index

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3" // sqlite driver (build tag sqlite_fts5)
)

// Event mirrors the on-disk JSONL row but only the fields the index
// surfaces back to callers. Optional fields are kept lowercase JSON for
// HTTP wire-format symmetry with the writer side.
type Event struct {
	ULID     string                 `json:"id"`
	TS       string                 `json:"ts"`
	TSUnix   int64                  `json:"ts_unix"`
	Host     string                 `json:"host"`
	Agent    string                 `json:"agent,omitempty"`
	Scope    string                 `json:"scope,omitempty"`
	Kind     string                 `json:"kind,omitempty"`
	Priority string                 `json:"priority,omitempty"`
	Path     string                 `json:"raw_jsonl_path,omitempty"`
	Offset   int64                  `json:"raw_byte_offset,omitempty"`
	Payload  map[string]any         `json:"payload"`
}

// QueryFilter restricts a Query() call.
type QueryFilter struct {
	Since    time.Time
	Until    time.Time
	Agent    string
	Scope    string
	Kind     string
	Priority string
	Host     string
	Limit    int
}

// Index wraps a single SQLite database connection.
type Index struct {
	db      *sql.DB
	path    string
	mu      sync.Mutex // serialises writes (ingest)
	cursors string     // path to cursors.json (incremental ingest state)
}

// NewIndex opens (or creates) the SQLite DB at dbPath and ensures schema.
// The cursors.json file is sibling to the DB.
func NewIndex(dbPath string) (*Index, error) {
	if dbPath == "" {
		return nil, errors.New("dbPath required")
	}
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir: %w", err)
	}
	dsn := fmt.Sprintf("file:%s?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on&_synchronous=NORMAL", dbPath)
	db, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1) // SQLite single writer; reads are fine on same conn under WAL
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	idx := &Index{db: db, path: dbPath, cursors: filepath.Join(filepath.Dir(dbPath), "cursors.json")}
	if err := idx.ensureSchema(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return idx, nil
}

// Close releases the underlying DB handle.
func (i *Index) Close() error { return i.db.Close() }

// Path returns the SQLite file path.
func (i *Index) Path() string { return i.path }

// schemaSQL is the canonical DDL — see ARCHITECTURE.md "Storage layout".
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
`

func (i *Index) ensureSchema() error {
	_, err := i.db.Exec(schemaSQL)
	if err != nil {
		return fmt.Errorf("schema: %w", err)
	}
	return nil
}

// Stats returns per-host counts and the latest ULID seen — used by /health.
type Stats struct {
	TotalEvents     int64    `json:"total_events"`
	LastIndexedULID string   `json:"last_indexed_ulid"`
	Hosts           []string `json:"hosts"`
}

// Stats reads global counters. Cheap (single COUNT, single MAX).
func (i *Index) Stats() (Stats, error) {
	var s Stats
	row := i.db.QueryRow(`SELECT COUNT(*), COALESCE(MAX(ulid), '') FROM events`)
	if err := row.Scan(&s.TotalEvents, &s.LastIndexedULID); err != nil {
		return s, err
	}
	rows, err := i.db.Query(`SELECT DISTINCT host FROM events ORDER BY host`)
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

// cursorMap is the on-disk representation of cursors.json.
type cursorMap map[string]int64 // path → byte offset

func (i *Index) loadCursors() (cursorMap, error) {
	buf, err := os.ReadFile(i.cursors)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cursorMap{}, nil
		}
		return nil, err
	}
	var m cursorMap
	if err := json.Unmarshal(buf, &m); err != nil || m == nil {
		return cursorMap{}, nil
	}
	return m, nil
}

func (i *Index) saveCursors(m cursorMap) error {
	if err := os.MkdirAll(filepath.Dir(i.cursors), 0o755); err != nil {
		return err
	}
	tmp := i.cursors + ".tmp"
	buf, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, buf, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, i.cursors)
}

// IngestJSONL reads new lines from path starting at the stored byte offset,
// inserts each into events + FTS5, and atomically updates cursors.json.
// Lines that fail to parse are skipped (one bad line ≠ aborted ingest).
//
// Returns count of events appended.
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
	startAt := cursors[abs]
	buf, err := os.ReadFile(abs)
	if err != nil {
		return 0, err
	}
	if int64(len(buf)) < startAt {
		startAt = 0 // truncation/rotation
	}
	tx, err := i.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.Prepare(`INSERT OR IGNORE INTO events
  (ulid, ts, ts_unix, host, agent, scope, kind, priority, raw_jsonl_path, raw_byte_offset, payload)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, json(?))`)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()
	count, offset := 0, startAt
	for offset < int64(len(buf)) {
		nl := bytes.IndexByte(buf[offset:], '\n')
		var lineEnd int64
		if nl < 0 { // last line w/o newline — leave for next ingest
			break
		}
		lineEnd = offset + int64(nl) + 1
		line := buf[offset : offset+int64(nl)]
		lineOffset := offset
		offset = lineEnd
		trimmed := strings.TrimSpace(string(line))
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
		tsUnix, _ := parseTimeUnix(ts)
		agent, _ := raw["agent"].(string)
		scope, _ := raw["scope"].(string)
		kind, _ := raw["kind"].(string)
		priority, _ := raw["priority"].(string)
		if _, err := stmt.Exec(ulid, ts, tsUnix, host, agent, scope, kind, priority, abs, lineOffset, trimmed); err != nil {
			return count, fmt.Errorf("insert ulid=%s: %w", ulid, err)
		}
		count++
	}
	if err := tx.Commit(); err != nil {
		return count, err
	}
	cursors[abs] = offset
	if err := i.saveCursors(cursors); err != nil {
		return count, fmt.Errorf("save cursors: %w", err)
	}
	return count, nil
}

// IngestDir ingests every events-*.jsonl in syncDir.
func (i *Index) IngestDir(syncDir string) (int, error) {
	matches, err := filepath.Glob(filepath.Join(syncDir, "events-*.jsonl"))
	if err != nil {
		return 0, err
	}
	total := 0
	for _, m := range matches {
		n, err := i.IngestJSONL(m)
		if err != nil {
			return total, fmt.Errorf("ingest %s: %w", m, err)
		}
		total += n
	}
	return total, nil
}

// Query returns events matching filter, sorted by ts_unix DESC.
func (i *Index) Query(f QueryFilter) ([]Event, error) {
	return i.QueryContext(context.Background(), f)
}

// QueryContext is the cancellable variant.
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
	sb.WriteString(` ORDER BY ts_unix DESC`)
	if f.Limit > 0 {
		sb.WriteString(` LIMIT ?`)
		args = append(args, f.Limit)
	}
	rows, err := i.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEvents(rows)
}

// Search runs an FTS5 BM25-ranked query. Pass `since` zero-value to skip filter.
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
	rows, err := i.db.Query(sb.String(), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanEvents(rows)
}

// Aggregate groups events by `by` (scope|agent|kind|host|priority) over the
// time window (today|24h|7d). Returns count map keyed by group.
func (i *Index) Aggregate(by, window string) (map[string]int, error) {
	col, ok := aggregateCol(by)
	if !ok {
		return nil, fmt.Errorf("unknown group_by %q", by)
	}
	since, err := windowSince(window)
	if err != nil {
		return nil, err
	}
	q := fmt.Sprintf(`SELECT COALESCE(%s,'(none)'), COUNT(*) FROM events WHERE ts_unix >= ? GROUP BY %s ORDER BY 2 DESC`, col, col)
	rows, err := i.db.Query(q, since.Unix())
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

// ----- helpers -----

func aggregateCol(by string) (string, bool) {
	switch by {
	case "scope", "agent", "kind", "host", "priority":
		return by, true
	}
	return "", false
}

// windowSince translates "today|24h|7d|<RFC3339>" into a since timestamp.
func windowSince(window string) (time.Time, error) {
	now := time.Now().UTC()
	switch window {
	case "", "24h":
		return now.Add(-24 * time.Hour), nil
	case "today":
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC), nil
	case "yesterday":
		y := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 0, 0, 0, time.UTC)
		return y, nil
	case "7d":
		return now.Add(-7 * 24 * time.Hour), nil
	}
	if t, err := time.Parse(time.RFC3339, window); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("unknown window %q", window)
}

// parseTimeUnix accepts the canonical "2006-01-02T15:04:05.000000Z" plus
// RFC3339 / RFC3339Nano fallbacks. Returns 0 if all fail (caller decides).
func parseTimeUnix(ts string) (int64, error) {
	for _, layout := range []string{
		"2006-01-02T15:04:05.000000Z",
		time.RFC3339Nano,
		time.RFC3339,
	} {
		if t, err := time.Parse(layout, ts); err == nil {
			return t.Unix(), nil
		}
	}
	return 0, fmt.Errorf("parse ts %q", ts)
}

// sanitizeFTS strips characters that break FTS5 MATCH expressions while
// preserving the user's words. Quotes the term so phrase-y queries also work.
func sanitizeFTS(q string) string {
	var sb strings.Builder
	q = strings.TrimSpace(q)
	for _, r := range q {
		if r == '"' || r == '\\' {
			continue
		}
		sb.WriteRune(r)
	}
	return `"` + sb.String() + `"`
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

