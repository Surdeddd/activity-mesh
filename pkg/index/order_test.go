package index

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func summariesNewestFirst(t *testing.T, idx *Index, limit int) []string {
	t.Helper()
	got, err := idx.Query(QueryFilter{Limit: limit})
	if err != nil {
		t.Fatal(err)
	}
	out := make([]string, len(got))
	for i, e := range got {
		out[i], _ = e.Payload["summary"].(string)
	}
	return out
}

func TestQueryLimitKeepsNewestEventWithinOneSecond(t *testing.T) {
	idx, dir := setupIndex(t)
	sec := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	at := func(ms int) string {
		return sec.Add(time.Duration(ms) * time.Millisecond).Format("2006-01-02T15:04:05.000000Z")
	}
	path := writeJSONL(t, filepath.Join(dir, "sync"), "h1", []string{
		buildLine(t, "01HRX00000000000000000SS01", at(100), "h1", "a", "s", "note", "", "first"),
		buildLine(t, "01HRX00000000000000000SS02", at(500), "h1", "a", "s", "note", "", "second"),
		buildLine(t, "01HRX00000000000000000SS03", at(900), "h1", "a", "s", "note", "", "third"),
	})
	if _, err := idx.IngestJSONL(path); err != nil {
		t.Fatal(err)
	}
	if got := summariesNewestFirst(t, idx, 1); fmt.Sprint(got) != "[third]" {
		t.Fatalf("newest-first LIMIT 1 returned %v, want [third]", got)
	}
	if got := summariesNewestFirst(t, idx, 0); fmt.Sprint(got) != "[third second first]" {
		t.Fatalf("newest-first order is %v, want [third second first]", got)
	}
}

func TestQueryBreaksIdenticalTimestampsByULIDDescending(t *testing.T) {
	idx, dir := setupIndex(t)
	ts := time.Now().UTC().Add(-time.Hour).Format("2006-01-02T15:04:05.000000Z")
	path := writeJSONL(t, filepath.Join(dir, "sync"), "h1", []string{
		buildLine(t, "01HRX00000000000000000TB01", ts, "h1", "a", "s", "note", "", "lower ulid"),
		buildLine(t, "01HRX00000000000000000TB02", ts, "h1", "a", "s", "note", "", "higher ulid"),
	})
	if _, err := idx.IngestJSONL(path); err != nil {
		t.Fatal(err)
	}
	if got := summariesNewestFirst(t, idx, 0); fmt.Sprint(got) != "[higher ulid lower ulid]" {
		t.Fatalf("identical timestamps ordered as %v, want the higher ULID first", got)
	}
}
