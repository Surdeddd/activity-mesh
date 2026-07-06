// Command activity-mesh-daemon serves the read API over HTTP. Watches per-host
// JSONL shards under ~/Sync/activity/ via fsnotify, ingests new lines into
// pkg/index (SQLite+FTS5). Endpoints: /health /recent /search /digest /push
// /metrics. Daemon-as-cache: every host can run; data is Syncthing-replicated.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/index"
	"github.com/Surdeddd/activity-mesh/pkg/redact"
	"github.com/Surdeddd/activity-mesh/pkg/shard"
)

// version is stamped at build time via -ldflags "-X main.version=...".
var version = "dev"

const (
	defaultPort     = 7459
	defaultRebuild  = 5 * time.Minute
	defaultStateDir = ".local/share/activity-mesh"
	defaultSyncDir  = "Sync/activity"
	defaultDBName   = "index.db"
)

type metrics struct {
	writes, queries, searches, digests, pushes, errors, ingested atomic.Uint64
	startedAt                                                    time.Time
}

type daemon struct {
	idx               *index.Index
	syncDir, stateDir string
	port              int
	m                 metrics
}

func main() {
	port := flag.Int("port", defaultPort, "HTTP listen port")
	bind := flag.String("bind", "", "listen address (default 127.0.0.1; set 0.0.0.0 to expose beyond localhost)")
	syncArg := flag.String("sync-dir", "", "override sync dir (default ~/Sync/activity)")
	stateArg := flag.String("state-dir", "", "override state dir (default ~/.local/share/activity-mesh)")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetOutput(os.Stderr)
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("home: %v", err)
	}
	pick := func(arg, env, def string) string {
		if arg != "" {
			return arg
		}
		if v := os.Getenv(env); v != "" {
			return v
		}
		return filepath.Join(home, def)
	}
	syncDir := pick(*syncArg, "ACTIVITY_MESH_SYNC", defaultSyncDir)
	stateDir := pick(*stateArg, "ACTIVITY_MESH_HOME", defaultStateDir)
	// The daemon serves the full activity history and accepts event pushes
	// with no authentication — localhost by default; exposing wider is an
	// explicit operator decision (--bind / ACTIVITY_MESH_BIND).
	bindAddr := *bind
	if bindAddr == "" {
		bindAddr = os.Getenv("ACTIVITY_MESH_BIND")
	}
	if bindAddr == "" {
		bindAddr = "127.0.0.1"
	}
	for _, p := range []string{syncDir, stateDir} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			log.Fatalf("mkdir %s: %v", p, err)
		}
	}
	idx, err := index.NewIndex(filepath.Join(stateDir, defaultDBName))
	if err != nil {
		log.Fatalf("index: %v", err)
	}
	defer idx.Close()
	d := &daemon{idx: idx, syncDir: syncDir, stateDir: stateDir, port: *port}
	d.m.startedAt = time.Now().UTC()
	if n, err := d.idx.IngestDir(syncDir); err != nil {
		d.m.errors.Add(1)
		log.Printf("initial ingest failed: %v", err)
	} else if n > 0 {
		d.m.ingested.Add(uint64(n))
		log.Printf("initial ingest: %d events", n)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	wg := sync.WaitGroup{}
	wg.Add(2)
	go func() { defer wg.Done(); d.watchSync(ctx) }()
	go func() { defer wg.Done(); d.periodicRebuild(ctx, defaultRebuild) }()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", d.handleHealth)
	mux.HandleFunc("/recent", d.handleRecent)
	mux.HandleFunc("/search", d.handleSearch)
	mux.HandleFunc("/digest", d.handleDigest)
	mux.HandleFunc("/push", d.handlePush)
	mux.HandleFunc("/metrics", d.handleMetrics)
	srv := &http.Server{
		Addr: net.JoinHostPort(bindAddr, strconv.Itoa(*port)), Handler: mux,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second,
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		log.Printf("activity-mesh-daemon %s listening on %s (sync=%s state=%s)", version, srv.Addr, syncDir, stateDir)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("server error: %v", err)
		}
	}()
	<-ctx.Done()
	log.Printf("shutdown received, draining...")
	shutdownCtx, sc := context.WithTimeout(context.Background(), 10*time.Second)
	defer sc()
	_ = srv.Shutdown(shutdownCtx)
	wg.Wait()
	log.Printf("daemon exited cleanly")
}

func (d *daemon) watchSync(ctx context.Context) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("fsnotify: %v", err)
		return
	}
	defer w.Close()
	if err := w.Add(d.syncDir); err != nil {
		log.Printf("watch %q: %v", d.syncDir, err)
		return
	}
	pending := map[string]time.Time{}
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			base := filepath.Base(ev.Name)
			if !strings.HasPrefix(base, "events-") || !strings.HasSuffix(base, ".jsonl") {
				continue
			}
			if ev.Op&(fsnotify.Write|fsnotify.Create) != 0 {
				pending[ev.Name] = time.Now()
			}
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			log.Printf("watcher error: %v", err)
		case now := <-tick.C:
			for path, last := range pending {
				if now.Sub(last) < 150*time.Millisecond {
					continue
				}
				delete(pending, path)
				if n, err := d.idx.IngestJSONL(path); err != nil {
					log.Printf("ingest %s: %v", path, err)
					d.m.errors.Add(1)
				} else if n > 0 {
					d.m.ingested.Add(uint64(n))
					log.Printf("ingested %d events from %s", n, filepath.Base(path))
				}
			}
		}
	}
}

func (d *daemon) periodicRebuild(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := d.idx.IngestDir(d.syncDir)
			if err != nil {
				log.Printf("periodic ingest: %v", err)
				d.m.errors.Add(1)
			} else if n > 0 {
				d.m.ingested.Add(uint64(n))
			}
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeErr(w http.ResponseWriter, code int, msg string) { writeJSON(w, code, map[string]string{"error": msg}) }
func (d *daemon) handleHealth(w http.ResponseWriter, r *http.Request) {
	stats, err := d.idx.Stats()
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                true,
		"version":           version,
		"last_indexed_ulid": stats.LastIndexedULID,
		"total_events":      stats.TotalEvents,
		"hosts":             stats.Hosts,
		"started_at":        d.m.startedAt.Format(time.RFC3339),
		"uptime_seconds":    int64(time.Since(d.m.startedAt).Seconds()),
	})
}

func (d *daemon) handleRecent(w http.ResponseWriter, r *http.Request) {
	d.m.queries.Add(1)
	q := r.URL.Query()
	hours := parseIntDefault(q.Get("hours"), 24, 24*366)
	limit := parseIntDefault(q.Get("limit"), 20, 1000)
	since := time.Now().UTC().Add(-time.Duration(hours) * time.Hour)
	events, err := d.idx.QueryContext(r.Context(), index.QueryFilter{
		Since: since, Scope: q.Get("scope"), Agent: q.Get("agent"),
		Kind: q.Get("kind"), Priority: q.Get("priority"), Host: q.Get("host"),
		Limit: limit,
	})
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": len(events), "events": events})
}

func (d *daemon) handleSearch(w http.ResponseWriter, r *http.Request) {
	d.m.searches.Add(1)
	q := r.URL.Query()
	query := strings.TrimSpace(q.Get("q"))
	if query == "" {
		writeErr(w, http.StatusBadRequest, "missing q parameter")
		return
	}
	limit := parseIntDefault(q.Get("limit"), 20, 1000)
	since := time.Time{}
	if s := q.Get("since"); s != "" {
		t, err := time.Parse(time.RFC3339, s)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "since must be RFC3339")
			return
		}
		since = t
	}
	hits, err := d.idx.Search(query, since, limit)
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"count": len(hits), "events": hits})
}

func (d *daemon) handleDigest(w http.ResponseWriter, r *http.Request) {
	d.m.digests.Add(1)
	q := r.URL.Query()
	window, groupBy := q.Get("window"), q.Get("group_by")
	if window == "" {
		window = "today"
	}
	if groupBy == "" {
		groupBy = "scope"
	}
	agg, err := d.idx.Aggregate(groupBy, window)
	if err != nil {
		d.m.errors.Add(1)
		// Unknown group_by/window are caller errors; anything else is ours.
		code := http.StatusInternalServerError
		if strings.HasPrefix(err.Error(), "unknown ") {
			code = http.StatusBadRequest
		}
		writeErr(w, code, err.Error())
		return
	}
	if strings.HasPrefix(r.Header.Get("Accept"), "application/json") || q.Get("format") == "json" {
		writeJSON(w, http.StatusOK, map[string]any{"window": window, "group_by": groupBy, "counts": agg})
		return
	}
	keys := make([]string, 0, len(agg))
	for k := range agg {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if agg[keys[i]] != agg[keys[j]] {
			return agg[keys[i]] > agg[keys[j]]
		}
		return keys[i] < keys[j]
	})
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	fmt.Fprintf(w, "# activity digest — %s by %s\n\n", window, groupBy)
	if len(keys) == 0 {
		_, _ = io.WriteString(w, "_no events_\n")
	}
	for _, k := range keys {
		fmt.Fprintf(w, "- **%s** — %d\n", k, agg[k])
	}
}

// handlePush accepts one event as JSON and appends it to the shard named by
// its host field. The payload is decoded into a generic map so extended
// schema fields survive; mandatory fields are validated, the host label is
// checked against the shard filename alphabet (path-traversal guard), the id
// must be a well-formed ULID (a junk id would permanently win MAX(ulid)),
// and the whole tree is redacted exactly like the CLI emit path — pushes
// must not be a side door around redaction. The append happens under the
// same per-host lock emit and compaction use.
func (d *daemon) handlePush(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	d.m.pushes.Add(1)
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 64*1024))
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	var p map[string]any
	if err := json.Unmarshal(body, &p); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid json")
		return
	}
	if v, ok := p["v"].(float64); !ok || v == 0 {
		p["v"] = event.SchemaVersion
	}
	str := func(k string) string { s, _ := p[k].(string); return s }
	id, ts, host := str("id"), str("ts"), str("host")
	if id == "" || ts == "" || host == "" || str("kind") == "" || str("scope") == "" || str("summary") == "" {
		writeErr(w, http.StatusBadRequest, "missing mandatory fields (id, ts, host, kind, scope, summary)")
		return
	}
	if !shard.ValidHost(host) {
		writeErr(w, http.StatusBadRequest, "invalid host label")
		return
	}
	if !event.ValidULID(id) {
		writeErr(w, http.StatusBadRequest, "id must be a 26-char ULID")
		return
	}
	if _, err := event.ParseTS(ts); err != nil {
		writeErr(w, http.StatusBadRequest, "ts must be RFC3339 or canonical event layout")
		return
	}
	cleaned, _ := redact.ApplyJSON(p)
	line, err := json.Marshal(cleaned)
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	lock, err := event.AcquireHostLock(d.stateDir, host)
	if err != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	appendErr := shard.AppendLocked(d.syncDir, host, line)
	_ = lock.Release()
	if appendErr != nil {
		d.m.errors.Add(1)
		writeErr(w, http.StatusInternalServerError, appendErr.Error())
		return
	}
	d.m.writes.Add(1)
	if n, err := d.idx.IngestJSONL(filepath.Join(d.syncDir, "events-"+host+".jsonl")); err != nil {
		d.m.errors.Add(1)
		log.Printf("post-push ingest: %v", err)
	} else {
		d.m.ingested.Add(uint64(n))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id, "priority": str("priority")})
}

func (d *daemon) handleMetrics(w http.ResponseWriter, r *http.Request) {
	stats, err := d.idx.Stats()
	if err != nil {
		d.m.errors.Add(1)
		log.Printf("metrics stats: %v", err)
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	c := func(name string, val uint64) { fmt.Fprintf(w, "# TYPE %s counter\n%s %d\n", name, name, val) }
	c("activity_mesh_writes_total", d.m.writes.Load())
	c("activity_mesh_queries_total", d.m.queries.Load())
	c("activity_mesh_searches_total", d.m.searches.Load())
	c("activity_mesh_digests_total", d.m.digests.Load())
	c("activity_mesh_pushes_total", d.m.pushes.Load())
	c("activity_mesh_errors_total", d.m.errors.Load())
	c("activity_mesh_ingested_events_total", d.m.ingested.Load())
	c("activity_mesh_uptime_seconds", uint64(time.Since(d.m.startedAt).Seconds()))
	fmt.Fprintf(w, "# TYPE activity_mesh_indexed_events gauge\nactivity_mesh_indexed_events %d\n", stats.TotalEvents)
}

// parseIntDefault parses s, falling back to def and clamping into
// [1, maxAllowed] — limit=0 must not mean "the whole table into memory".
func parseIntDefault(s string, def, maxAllowed int) int {
	n, err := strconv.Atoi(s)
	if s == "" || err != nil || n <= 0 {
		n = def
	}
	if n > maxAllowed {
		n = maxAllowed
	}
	return n
}
