// Regression for the P0 lost-append race: an emit landing while compaction
// reads-rewrites-renames the shard must never be destroyed. Both sides now
// hold the per-host lock for their whole critical section.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/shard"
)

func TestEmitDuringCompactLosesNothing(t *testing.T) {
	storeDir, syncDir := setupTempEnv(t)
	host := event.HostName()
	shardPath := filepath.Join(syncDir, "events-"+host+".jsonl")

	// Seed 2000 archivable events so the compaction window is wide enough
	// for concurrent emits to land inside it.
	old := time.Now().UTC().Add(-120 * 24 * time.Hour).Format("2006-01-02T15:04:05.000000Z")
	var sb strings.Builder
	for i := 0; i < 2000; i++ {
		fmt.Fprintf(&sb, `{"v":1,"id":"01ARZ3NDEKTSV4RRFFQ69G%04d","ts":%q,"host":%q,"agent":"t","kind":"note","scope":"s","summary":"old %d"}`+"\n", i, old, host, i)
	}
	if err := os.WriteFile(shardPath, []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	const emitters, perEmitter = 4, 25
	var wg sync.WaitGroup
	errCh := make(chan error, emitters*perEmitter+1)

	wg.Add(1)
	go func() {
		defer wg.Done()
		_, err := compactShard(compactOptions{
			shardPath:  shardPath,
			archiveDir: filepath.Join(syncDir, "archive"),
			host:       host,
			storeDir:   storeDir,
			cutoff:     time.Now().UTC().Add(-90 * 24 * time.Hour),
		})
		if err != nil {
			errCh <- fmt.Errorf("compact: %w", err)
		}
	}()

	for g := 0; g < emitters; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < perEmitter; i++ {
				lock, err := event.AcquireHostLock(storeDir, host)
				if err != nil {
					errCh <- err
					return
				}
				ev, err := event.NewLocked(lock, "note", "s", fmt.Sprintf("live-%d-%d", g, i))
				if err != nil {
					_ = lock.Release()
					errCh <- err
					return
				}
				line, _, err := ev.Marshal()
				if err == nil {
					err = shard.AppendLocked(syncDir, ev.Host, line)
				}
				_ = lock.Release()
				if err != nil {
					errCh <- err
					return
				}
			}
		}(g)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(shardPath)
	if err != nil {
		t.Fatal(err)
	}
	got := 0
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.Contains(line, `"summary":"live-`) {
			got++
		}
	}
	if want := emitters * perEmitter; got != want {
		t.Fatalf("lost appends during compaction: want %d live events in shard, got %d", want, got)
	}
}
