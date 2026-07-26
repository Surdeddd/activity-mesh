package tests

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/shard"
)

// The v1.0 release gate reads "1000 concurrent appends from 3 hosts → 0
// sync-conflict files", and nothing in the repo exercised it: the write-path
// invariants (one writer per shard, locked append, a monotonic_seq that is
// allocated exactly once) had no concurrency test at all.
//
// This covers the half that is mechanizable on one machine — 1000 racing
// appends across three shards. The Syncthing half still needs three real hosts,
// so the ROADMAP entry stays open.
func TestConcurrentAppendsAreConflictFree(t *testing.T) {
	const (
		hostCount     = 3
		writersPerHst = 8
		perWriter     = 42 // 3 * 8 * 42 = 1008 appends
	)
	syncDir := t.TempDir()
	storeDir := t.TempDir()

	hosts := make([]string, hostCount)
	for i := range hosts {
		hosts[i] = fmt.Sprintf("host-%d", i+1)
	}

	// Every writer races every other, including the ones sharing its shard.
	var wg sync.WaitGroup
	errs := make(chan error, hostCount*writersPerHst*perWriter)
	start := make(chan struct{})
	for _, host := range hosts {
		for w := 0; w < writersPerHst; w++ {
			wg.Add(1)
			go func(host string, w int) {
				defer wg.Done()
				<-start
				for n := 0; n < perWriter; n++ {
					if err := appendOne(syncDir, storeDir, host, w, n); err != nil {
						errs <- err
						return
					}
				}
			}(host, w)
		}
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatalf("append failed: %v", err)
	}

	wantPerHost := writersPerHst * perWriter
	total := 0
	for _, host := range hosts {
		path, err := shard.Path(syncDir, host)
		if err != nil {
			t.Fatal(err)
		}
		seqs, ids := readShard(t, path)

		if len(seqs) != wantPerHost {
			t.Errorf("%s: %d events on disk, want %d — an append was lost or doubled", host, len(seqs), wantPerHost)
		}
		total += len(seqs)

		// The counter is the ordering invariant: allocated under the same lock
		// that guards the append, so across all writers it must come out as
		// exactly 1..N with no duplicate and no gap.
		seen := make(map[uint64]bool, len(seqs))
		for _, s := range seqs {
			if seen[s] {
				t.Errorf("%s: monotonic_seq %d allocated twice", host, s)
			}
			seen[s] = true
		}
		for i := uint64(1); i <= uint64(wantPerHost); i++ {
			if !seen[i] {
				t.Errorf("%s: monotonic_seq %d never allocated", host, i)
				break
			}
		}

		uniqueIDs := make(map[string]bool, len(ids))
		for _, id := range ids {
			if uniqueIDs[id] {
				t.Errorf("%s: event id %s written twice", host, id)
			}
			uniqueIDs[id] = true
		}
	}

	if total != hostCount*wantPerHost {
		t.Errorf("total events %d, want %d", total, hostCount*wantPerHost)
	}

	// Nothing in the write path may ever produce a Syncthing conflict copy:
	// one host owns one shard file, so the two writers a conflict needs cannot
	// exist by construction.
	conflicts, err := filepath.Glob(filepath.Join(syncDir, "*sync-conflict*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(conflicts) != 0 {
		t.Errorf("sync-conflict files appeared: %v", conflicts)
	}

	// Each host writes its own file and no other.
	shards, err := filepath.Glob(filepath.Join(syncDir, "events-*.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if len(shards) != hostCount {
		t.Errorf("%d shard files, want %d: %v", len(shards), hostCount, shards)
	}
}

func appendOne(syncDir, storeDir, host string, writer, n int) error {
	lock, err := event.AcquireHostLock(storeDir, host)
	if err != nil {
		return fmt.Errorf("lock: %w", err)
	}
	defer lock.Release() //nolint:errcheck

	ev, err := event.NewLocked(lock, "canary", "test:conflict", fmt.Sprintf("w%d-n%d", writer, n))
	if err != nil {
		return fmt.Errorf("new event: %w", err)
	}
	ev.Host = host // NewLocked stamps the real machine name; we simulate three
	line, _, err := ev.Marshal()
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	return shard.AppendLocked(syncDir, host, line)
}

// readShard parses every line, which is itself the assertion that no append
// interleaved into another: a torn or glued line does not unmarshal.
func readShard(t *testing.T, path string) (seqs []uint64, ids []string) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open shard: %v", err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	for lineNo := 1; sc.Scan(); lineNo++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var e event.Event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("%s:%d is not a single JSON object (interleaved append?): %v\nline: %q",
				filepath.Base(path), lineNo, err, truncate(line))
		}
		seqs = append(seqs, e.MonotonicSeq)
		ids = append(ids, e.ID)
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan shard: %v", err)
	}
	return seqs, ids
}

func truncate(s string) string {
	if len(s) <= 160 {
		return s
	}
	return s[:160] + "…"
}
