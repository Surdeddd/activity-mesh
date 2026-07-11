package event

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/oklog/ulid/v2"

	"github.com/Surdeddd/activity-mesh/pkg/redact"
)

const SchemaVersion = 1

type RedactHit = redact.Hit

type Event struct {
	V             int      `json:"v"`
	ID            string   `json:"id"`
	TS            string   `json:"ts"`
	Host          string   `json:"host"`
	Agent         string   `json:"agent"`
	Kind          string   `json:"kind"`
	Scope         string   `json:"scope"`
	Summary       string   `json:"summary"`
	MonotonicSeq  uint64   `json:"monotonic_seq,omitempty"`
	TSMonoNS      int64    `json:"ts_mono_ns,omitempty"`
	BootID        string   `json:"boot_id,omitempty"`
	SessionID     string   `json:"session_id,omitempty"`
	ParentID      string   `json:"parent_id,omitempty"`
	CausedBy      string   `json:"caused_by,omitempty"`
	Actor         string   `json:"actor,omitempty"`
	Originator    string   `json:"originator,omitempty"`
	Ref           string   `json:"ref,omitempty"`
	Tags          []string `json:"tags,omitempty"`
	DurationMS    int64    `json:"duration_ms,omitempty"`
	ExitCode      *int     `json:"exit_code,omitempty"`
	Files         []string `json:"files,omitempty"`
	Truncated     bool     `json:"truncated,omitempty"`
	ClockOffsetMS int64    `json:"clock_offset_ms,omitempty"`
	Priority      string   `json:"priority,omitempty"`
}

type Option func(*Event)

func WithRef(ref string) Option { return func(e *Event) { e.Ref = ref } }

func WithTags(tags []string) Option { return func(e *Event) { e.Tags = tags } }

func WithPriority(p string) Option { return func(e *Event) { e.Priority = p } }

func WithAgent(a string) Option { return func(e *Event) { e.Agent = a } }

func WithSessionID(id string) Option { return func(e *Event) { e.SessionID = id } }

func WithParentID(id string) Option { return func(e *Event) { e.ParentID = id } }

func New(storeDir, kind, scope, summary string, opts ...Option) (*Event, error) {
	host := HostName()
	lock, err := AcquireHostLock(storeDir, host)
	if err != nil {
		return nil, fmt.Errorf("seq: %w", err)
	}
	defer lock.Release() //nolint:errcheck
	return NewLocked(lock, kind, scope, summary, opts...)
}

func NewLocked(lock *HostLock, kind, scope, summary string, opts ...Option) (*Event, error) {
	host := HostName()
	id, err := newULID()
	if err != nil {
		return nil, fmt.Errorf("ulid: %w", err)
	}
	seq, err := lock.NextSeq()
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
	if ms, ok := readClockOffsetMS(ClockOffsetPath()); ok {
		e.ClockOffsetMS = ms
	}
	for _, o := range opts {
		o(e)
	}
	return e, nil
}

func (e *Event) Marshal() (line []byte, hits []RedactHit, err error) {
	sanitizeStruct(e)

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

func defaultAgent() string {
	if a := os.Getenv("ACTIVITY_AGENT"); a != "" {
		return a
	}
	return "cli"
}

var TSLayouts = []string{
	"2006-01-02T15:04:05.000000Z",
	time.RFC3339Nano,
	time.RFC3339,
}

func ParseTS(ts string) (time.Time, error) {
	for _, layout := range TSLayouts {
		if t, err := time.Parse(layout, ts); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("parse ts %q", ts)
}

func ValidULID(s string) bool {
	_, err := ulid.ParseStrict(s)
	return err == nil
}

const MaxSummaryRunes = 500

func NormalizeSummary(s string) (string, bool) {
	r := []rune(s)
	if len(r) <= MaxSummaryRunes {
		return s, false
	}
	return string(r[:MaxSummaryRunes-1]) + "…", true
}

func ValidPriority(p string) bool {
	switch p {
	case "", "P0", "P1", "P2", "P3":
		return true
	}
	return false
}
