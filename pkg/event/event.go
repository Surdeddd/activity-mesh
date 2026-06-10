// Package event defines the activity-mesh event schema and helpers for
// generating ULIDs + monotonic_seq + UTF-8 sanitized JSONL output.
package event

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/oklog/ulid/v2"

	"github.com/Surdeddd/activity-mesh/pkg/redact"
)

// SchemaVersion of the event format.
const SchemaVersion = 1

// RedactHit is re-exported from pkg/redact for callers that want a single import.
type RedactHit = redact.Hit

// Event is the on-disk representation. JSON tags use omitempty for optional
// fields to keep ambient token cost down.
type Event struct {
	V              int      `json:"v"`
	ID             string   `json:"id"`
	TS             string   `json:"ts"`
	Host           string   `json:"host"`
	Agent          string   `json:"agent"`
	Kind           string   `json:"kind"`
	Scope          string   `json:"scope"`
	Summary        string   `json:"summary"`
	MonotonicSeq   uint64   `json:"monotonic_seq,omitempty"`
	TSMonoNS       int64    `json:"ts_mono_ns,omitempty"`
	BootID         string   `json:"boot_id,omitempty"`
	SessionID      string   `json:"session_id,omitempty"`
	ParentID       string   `json:"parent_id,omitempty"`
	CausedBy       string   `json:"caused_by,omitempty"`
	Actor          string   `json:"actor,omitempty"`
	Originator     string   `json:"originator,omitempty"`
	Ref            string   `json:"ref,omitempty"`
	Tags           []string `json:"tags,omitempty"`
	DurationMS     int64    `json:"duration_ms,omitempty"`
	ExitCode       *int     `json:"exit_code,omitempty"`
	Files          []string `json:"files,omitempty"`
	Truncated      bool     `json:"truncated,omitempty"`
	ClockOffsetMS  int64    `json:"clock_offset_ms,omitempty"`
	Priority       string   `json:"priority,omitempty"`
}

// Option mutates an event during construction.
type Option func(*Event)

// WithRef sets the optional ref pointer (wiki://, git://, file://).
func WithRef(ref string) Option { return func(e *Event) { e.Ref = ref } }

// WithTags attaches a tag list.
func WithTags(tags []string) Option { return func(e *Event) { e.Tags = tags } }

// WithPriority sets P0..P3.
func WithPriority(p string) Option { return func(e *Event) { e.Priority = p } }

// WithAgent overrides the auto-detected agent label.
func WithAgent(a string) Option { return func(e *Event) { e.Agent = a } }

// WithSessionID attaches a session identifier.
func WithSessionID(id string) Option { return func(e *Event) { e.SessionID = id } }

// WithParentID links to a parent event (causal chain).
func WithParentID(id string) Option { return func(e *Event) { e.ParentID = id } }

// New constructs a fresh event. ULID, timestamp, and monotonic_seq are filled
// automatically from the SeqStore at storeDir.
func New(storeDir, kind, scope, summary string, opts ...Option) (*Event, error) {
	host, _ := os.Hostname()
	host = strings.TrimSpace(host)
	if host == "" {
		host = "unknown"
	}
	id, err := newULID()
	if err != nil {
		return nil, fmt.Errorf("ulid: %w", err)
	}
	seq, err := nextSeq(storeDir, host)
	if err != nil {
		return nil, fmt.Errorf("seq: %w", err)
	}
	e := &Event{
		V:            SchemaVersion,
		ID:           id,
		TS:           time.Now().UTC().Format("2006-01-02T15:04:05.000000Z"),
		Host:         host,
		Agent:        defaultAgent(),
		Kind:         kind,
		Scope:        scope,
		Summary:      summary,
		MonotonicSeq: seq,
	}
	// Cached NTP offset (written by `activity-log clock-sync`). Cheap single
	// read; missing/garbage file → field omitted, never an error.
	if ms, ok := readClockOffsetMS(ClockOffsetPath()); ok {
		e.ClockOffsetMS = ms
	}
	for _, o := range opts {
		o(e)
	}
	return e, nil
}

// Marshal applies redaction to all string fields, validates UTF-8 (replacing
// invalid bytes with U+FFFD and setting truncated=true), and produces a single
// JSONL line WITHOUT a trailing newline. Returned hits feed the audit log.
func (e *Event) Marshal() (line []byte, hits []RedactHit, err error) {
	// 1. UTF-8 sanitize on the source event before any JSON round-trip.
	//    json.Marshal silently replaces invalid bytes with U+FFFD, so we
	//    must detect+flag here.
	sanitizeStruct(e)

	// 2. Encode to a generic map so we can apply redaction recursively, then
	//    re-marshal. A bit slower but keeps redaction scope-complete.
	raw, err := json.Marshal(e)
	if err != nil {
		return nil, nil, err
	}
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, nil, err
	}
	cleaned, hits := redact.ApplyJSON(generic)
	out, err := json.Marshal(cleaned)
	if err != nil {
		return nil, nil, err
	}
	return out, hits, nil
}

// sanitizeStruct rewrites every user-supplied string field in e to be valid
// UTF-8, replacing invalid bytes with U+FFFD and flagging Truncated=true.
func sanitizeStruct(e *Event) {
	clean := func(s *string) {
		if !utf8.ValidString(*s) {
			*s = strings.ToValidUTF8(*s, "�")
			e.Truncated = true
		}
	}
	clean(&e.Summary)
	clean(&e.Scope)
	clean(&e.Kind)
	clean(&e.Agent)
	clean(&e.Host)
	clean(&e.Ref)
	clean(&e.Actor)
	clean(&e.Originator)
	clean(&e.SessionID)
	clean(&e.ParentID)
	clean(&e.CausedBy)
	clean(&e.Priority)
	for i := range e.Tags {
		clean(&e.Tags[i])
	}
	for i := range e.Files {
		clean(&e.Files[i])
	}
}

// ----- ULID + seq -----

var (
	ulidEntropy *ulidEntropySource
	ulidOnce    sync.Once
)

type ulidEntropySource struct {
	mu sync.Mutex
}

func (s *ulidEntropySource) Read(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return rand.Read(p)
}

func newULID() (string, error) {
	ulidOnce.Do(func() { ulidEntropy = &ulidEntropySource{} })
	t := ulid.Timestamp(time.Now())
	id, err := ulid.New(t, ulidEntropy)
	if err != nil {
		return "", err
	}
	return id.String(), nil
}

// nextSeq increments the per-host monotonic counter at storeDir/seq-<host>
// using POSIX advisory file locking (flock). The counter is durable across
// process restarts.
func nextSeq(storeDir, host string) (uint64, error) {
	if storeDir == "" {
		return 0, errors.New("storeDir required")
	}
	if err := os.MkdirAll(storeDir, 0o755); err != nil {
		return 0, err
	}
	path := filepath.Join(storeDir, "seq-"+host)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if err := flockExclusive(f); err != nil {
		return 0, err
	}
	defer flockRelease(f) //nolint:errcheck
	// Read from the locked handle, not a fresh os.ReadFile(path): on Windows
	// LockFileEx is a mandatory byte-range lock, so a second handle reading the
	// locked region fails ("another process has locked a portion of the file").
	// The handle holding the lock can always read it.
	buf, err := io.ReadAll(f)
	if err != nil {
		return 0, err
	}
	var current uint64
	if len(buf) > 0 {
		// trim whitespace/newline tolerantly
		s := strings.TrimSpace(string(buf))
		if n, perr := strconv.ParseUint(s, 10, 64); perr == nil {
			current = n
		}
	}
	current++
	if _, err := f.Seek(0, 0); err != nil {
		return 0, err
	}
	if err := f.Truncate(0); err != nil {
		return 0, err
	}
	if _, err := f.WriteString(strconv.FormatUint(current, 10) + "\n"); err != nil {
		return 0, err
	}
	if err := f.Sync(); err != nil {
		return 0, err
	}
	return current, nil
}

// defaultAgent infers the writer label from $ACTIVITY_AGENT env or hostname.
func defaultAgent() string {
	if a := os.Getenv("ACTIVITY_AGENT"); a != "" {
		return a
	}
	return "cli"
}

// randomFallback used only if rand fails — last-ditch entropy from time.
func randomFallback() *big.Int { //nolint:unused
	return big.NewInt(time.Now().UnixNano())
}
