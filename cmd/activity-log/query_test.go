package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Surdeddd/activity-mesh/pkg/event"
)

func queryLine(id, ts string, seq int, summary string) string {
	return fmt.Sprintf(`{"v":1,"id":%q,"ts":%q,"host":"h","agent":"a","kind":"note","scope":"s","summary":%q,"monotonic_seq":%d}`, id, ts, summary, seq)
}

func writeQueryShard(t *testing.T, syncDir string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(syncDir, "events-h.jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func queryEvents(t *testing.T, args ...string) []event.Event {
	t.Helper()
	cmd := queryCmd()
	cmd.SetArgs(append([]string{"--format", "json"}, args...))
	out, err := captureStdout(t, cmd.Execute)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	var got []event.Event
	dec := json.NewDecoder(strings.NewReader(out))
	for dec.More() {
		var e event.Event
		if err := dec.Decode(&e); err != nil {
			t.Fatalf("decode %q: %v", out, err)
		}
		got = append(got, e)
	}
	return got
}

func summariesOf(events []event.Event) []string {
	out := make([]string, len(events))
	for i, e := range events {
		out[i] = e.Summary
	}
	return out
}

func TestQueryLimitKeepsNewestEventAcrossTimestampOffsets(t *testing.T) {
	syncDir, _, _ := sandboxEnv(t)
	now := time.Now().UTC()
	older := now.Add(-2 * time.Hour).In(time.FixedZone("MSK", 3*3600)).Format(time.RFC3339Nano)
	newer := now.Add(-1 * time.Hour).Format("2006-01-02T15:04:05.000000Z")
	writeQueryShard(t, syncDir,
		queryLine("01HRX0000000000000000000Q1", older, 1, "older (pushed with +03:00)"),
		queryLine("01HRX0000000000000000000Q2", newer, 2, "newer"),
	)
	if got := summariesOf(queryEvents(t, "--limit", "1")); fmt.Sprint(got) != "[newer]" {
		t.Fatalf("query --limit 1 returned %v, want the most recent event [newer]", got)
	}
	if got := summariesOf(queryEvents(t, "--limit", "0")); fmt.Sprint(got) != "[older (pushed with +03:00) newer]" {
		t.Fatalf("query --limit 0 returned %v, want oldest first", got)
	}
}

func TestQueryBreaksEqualInstantsBySequenceThenID(t *testing.T) {
	syncDir, _, _ := sandboxEnv(t)
	msk := time.FixedZone("MSK", 3*3600)
	first := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Second)
	second := first.Add(time.Hour)
	canonical := func(at time.Time) string { return at.Format("2006-01-02T15:04:05.000000Z") }
	offset := func(at time.Time) string { return at.In(msk).Format(time.RFC3339Nano) }
	writeQueryShard(t, syncDir,
		queryLine("01HRX0000000000000000000E1", canonical(first), 2, "seq 2"),
		queryLine("01HRX0000000000000000000E2", offset(first), 1, "seq 1"),
		queryLine("01HRX0000000000000000000E4", canonical(second), 0, "id 4"),
		queryLine("01HRX0000000000000000000E3", offset(second), 0, "id 3"),
	)
	want := "[seq 1 seq 2 id 3 id 4]"
	if got := summariesOf(queryEvents(t, "--limit", "0")); fmt.Sprint(got) != want {
		t.Fatalf("equal instants ordered as %v, want %s", got, want)
	}
}

func TestQueryTreatsUnparseableTimestampsAsOldest(t *testing.T) {
	syncDir, _, _ := sandboxEnv(t)
	now := time.Now().UTC()
	canonical := func(at time.Time) string { return at.Format("2006-01-02T15:04:05.000000Z") }
	writeQueryShard(t, syncDir,
		queryLine("01HRX0000000000000000000U1", canonical(now.Add(-1*time.Hour)), 1, "latest"),
		queryLine("01HRX0000000000000000000U2", canonical(now.Add(-2*time.Hour)), 9, "earlier"),
		queryLine("01HRX0000000000000000000U3", "not-a-time", 5, "garbled"),
	)
	if got := summariesOf(queryEvents(t, "--since", "", "--limit", "1")); fmt.Sprint(got) != "[latest]" {
		t.Fatalf("query --limit 1 returned %v, want [latest]", got)
	}
	want := "[garbled earlier latest]"
	if got := summariesOf(queryEvents(t, "--since", "", "--limit", "0")); fmt.Sprint(got) != want {
		t.Fatalf("query --limit 0 returned %v, want %s", got, want)
	}
}
