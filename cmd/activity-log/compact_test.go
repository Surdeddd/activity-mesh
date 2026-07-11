package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func evLine(ts, id string) string {
	return `{"v":1,"id":"` + id + `","ts":"` + ts + `","host":"testhost","agent":"cli","kind":"note","scope":"scope:test","summary":"` + id + `"}`
}

var compactCutoff = time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)

const (
	tsJan  = "2026-01-15T10:00:00.000000Z"
	tsFebA = "2026-02-01T00:00:00.000000Z"
	tsFebB = "2026-02-20T23:59:59.000000Z"
	tsMar  = "2026-03-10T12:00:00.000000Z"
)

func mixedShard() []byte {
	lines := []string{
		evLine(tsJan, "OLD-JAN"),
		`{this is not json`,
		evLine(tsFebA, "OLD-FEB-A"),
		"",
		`{"id":"BADTS","ts":"yesterday","summary":"unparseable ts"}`,
		evLine(tsFebB, "OLD-FEB-B"),
		evLine(tsMar, "NEW-MAR"),
	}
	return []byte(strings.Join(lines, "\n") + "\n" + evLine(tsMar, "PARTIAL-TAIL"))
}

func TestPartitionShard(t *testing.T) {
	p := partitionShard(mixedShard(), compactCutoff)
	if p.archivedCount != 3 {
		t.Fatalf("archived = %d, want 3", p.archivedCount)
	}
	if got := len(p.archive["2026-01"]); got != 1 {
		t.Errorf("2026-01 lines = %d, want 1", got)
	}
	if got := len(p.archive["2026-02"]); got != 2 {
		t.Errorf("2026-02 lines = %d, want 2", got)
	}
	if p.keptEvents != 2 {
		t.Errorf("keptEvents = %d, want 2", p.keptEvents)
	}
	if p.malformed != 2 {
		t.Errorf("malformed = %d, want 2", p.malformed)
	}
	wantKeep := `{this is not json` + "\n" +
		"\n" +
		`{"id":"BADTS","ts":"yesterday","summary":"unparseable ts"}` + "\n" +
		evLine(tsMar, "NEW-MAR") + "\n" +
		evLine(tsMar, "PARTIAL-TAIL") // no trailing newline — preserved byte-exact
	if string(p.keep) != wantKeep {
		t.Errorf("keep mismatch:\n got: %q\nwant: %q", p.keep, wantKeep)
	}
	if !bytes.Contains(p.archive["2026-02"][0], []byte("OLD-FEB-A")) ||
		!bytes.Contains(p.archive["2026-02"][1], []byte("OLD-FEB-B")) {
		t.Errorf("2026-02 archive order not preserved: %q", p.archive["2026-02"])
	}
}

func gunzipAll(t *testing.T, path string) string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open archive: %v", err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f) // multistream by default
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	defer gz.Close()
	buf, err := io.ReadAll(gz)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	return string(buf)
}

func writeShard(t *testing.T, dir string, content []byte) string {
	t.Helper()
	path := filepath.Join(dir, "events-testhost.jsonl")
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCompactShardEndToEnd(t *testing.T) {
	dir := t.TempDir()
	shard := writeShard(t, dir, mixedShard())
	res, err := compactShard(compactOptions{
		shardPath:  shard,
		archiveDir: filepath.Join(dir, "archive"),
		host:       "testhost",
		storeDir:   filepath.Join(dir, "store"), // exercises the emit flock path
		cutoff:     compactCutoff,
	})
	if err != nil {
		t.Fatalf("compactShard: %v", err)
	}
	if res.archived != 3 || res.kept != 2 || res.malformed != 2 {
		t.Errorf("counts = archived %d kept %d malformed %d, want 3/2/2", res.archived, res.kept, res.malformed)
	}
	live, err := os.ReadFile(shard)
	if err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{"OLD-JAN", "OLD-FEB-A", "OLD-FEB-B"} {
		if bytes.Contains(live, []byte(gone)) {
			t.Errorf("live shard still contains %s", gone)
		}
	}
	for _, kept := range []string{"{this is not json", "BADTS", "NEW-MAR", "PARTIAL-TAIL"} {
		if !bytes.Contains(live, []byte(kept)) {
			t.Errorf("live shard lost %q", kept)
		}
	}
	if bytes.HasSuffix(live, []byte("\n")) {
		t.Errorf("partial trailing line gained a newline")
	}
	if fi, err := os.Stat(shard); err != nil {
		t.Fatal(err)
	} else if runtimePerms := fi.Mode().Perm(); os.PathSeparator == '/' && runtimePerms != 0o644 {
		t.Errorf("shard perms = %o, want 0644", runtimePerms)
	}
	if len(res.months) != 2 || res.months[0].month != "2026-01" || res.months[1].month != "2026-02" {
		t.Fatalf("months = %+v, want 2026-01 then 2026-02", res.months)
	}
	jan := gunzipAll(t, res.months[0].file)
	if !strings.Contains(jan, "OLD-JAN") || strings.Count(jan, "\n") != 1 {
		t.Errorf("jan archive wrong: %q", jan)
	}
	feb := gunzipAll(t, res.months[1].file)
	if !strings.Contains(feb, "OLD-FEB-A") || !strings.Contains(feb, "OLD-FEB-B") || strings.Count(feb, "\n") != 2 {
		t.Errorf("feb archive wrong: %q", feb)
	}
}

func TestCompactArchiveAppendsGzipMember(t *testing.T) {
	dir := t.TempDir()
	archiveDir := filepath.Join(dir, "archive")
	run := func(content []byte) *compactResult {
		t.Helper()
		shard := writeShard(t, dir, content)
		res, err := compactShard(compactOptions{
			shardPath:  shard,
			archiveDir: archiveDir,
			host:       "testhost",
			cutoff:     compactCutoff,
		})
		if err != nil {
			t.Fatalf("compactShard: %v", err)
		}
		return res
	}
	first := run([]byte(evLine(tsFebA, "RUN1") + "\n"))
	sizeAfterFirst, err := os.Stat(first.months[0].file)
	if err != nil {
		t.Fatal(err)
	}
	second := run([]byte(evLine(tsFebB, "RUN2") + "\n"))
	if first.months[0].file != second.months[0].file {
		t.Fatalf("runs hit different archives: %s vs %s", first.months[0].file, second.months[0].file)
	}
	sizeAfterSecond, err := os.Stat(second.months[0].file)
	if err != nil {
		t.Fatal(err)
	}
	if sizeAfterSecond.Size() <= sizeAfterFirst.Size() {
		t.Errorf("archive did not grow: %d → %d", sizeAfterFirst.Size(), sizeAfterSecond.Size())
	}
	all := gunzipAll(t, second.months[0].file)
	if !strings.Contains(all, "RUN1") || !strings.Contains(all, "RUN2") {
		t.Errorf("multistream read missing rows: %q", all)
	}
	if strings.Count(all, "\n") != 2 {
		t.Errorf("expected 2 rows across members, got: %q", all)
	}
}

func TestCompactDryRun(t *testing.T) {
	dir := t.TempDir()
	content := mixedShard()
	shard := writeShard(t, dir, content)
	res, err := compactShard(compactOptions{
		shardPath:  shard,
		archiveDir: filepath.Join(dir, "archive"),
		host:       "testhost",
		cutoff:     compactCutoff,
		dryRun:     true,
	})
	if err != nil {
		t.Fatalf("compactShard: %v", err)
	}
	if res.archived != 3 || len(res.months) != 2 {
		t.Errorf("dry-run counts wrong: %+v", res)
	}
	after, err := os.ReadFile(shard)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, content) {
		t.Errorf("dry-run modified the live shard")
	}
	if _, err := os.Stat(filepath.Join(dir, "archive")); !os.IsNotExist(err) {
		t.Errorf("dry-run created the archive dir")
	}
}

func TestCompactNothingToArchive(t *testing.T) {
	dir := t.TempDir()
	content := []byte(evLine(tsMar, "RECENT") + "\n")
	shard := writeShard(t, dir, content)
	res, err := compactShard(compactOptions{
		shardPath:  shard,
		archiveDir: filepath.Join(dir, "archive"),
		host:       "testhost",
		cutoff:     compactCutoff,
	})
	if err != nil {
		t.Fatalf("compactShard: %v", err)
	}
	if res.archived != 0 || res.kept != 1 {
		t.Errorf("counts = %+v, want archived 0 kept 1", res)
	}
	after, err := os.ReadFile(shard)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, content) {
		t.Errorf("no-op compaction modified the live shard")
	}
	if _, err := os.Stat(filepath.Join(dir, "archive")); !os.IsNotExist(err) {
		t.Errorf("no-op compaction created the archive dir")
	}
}

func TestCompactMissingShard(t *testing.T) {
	dir := t.TempDir()
	res, err := compactShard(compactOptions{
		shardPath:  filepath.Join(dir, "events-testhost.jsonl"),
		archiveDir: filepath.Join(dir, "archive"),
		host:       "testhost",
		cutoff:     compactCutoff,
	})
	if err != nil {
		t.Fatalf("compactShard: %v", err)
	}
	if !res.missing {
		t.Errorf("expected missing=true")
	}
}
