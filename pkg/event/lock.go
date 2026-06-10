// Per-host identity + advisory locking shared by the emit path and shard
// maintenance (compaction).
package event

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// HostName returns the canonical host label used in shard names
// (events-<host>.jsonl): os.Hostname() trimmed, "unknown" fallback.
// Same resolution New() uses, exported so maintenance commands resolve
// the identical shard path.
func HostName() string {
	host, _ := os.Hostname()
	host = strings.TrimSpace(host)
	if host == "" {
		host = "unknown"
	}
	return host
}

// AcquireHostLock takes the exclusive per-host advisory lock the emit path
// uses (flock on storeDir/seq-<host>, see nextSeq). While held, no emit on
// this host can allocate a monotonic_seq, which serialises shard maintenance
// (compaction's rewrite-and-rename) against new appends.
//
// Residual window: an emit that already passed nextSeq but has not yet
// opened the shard for O_APPEND is not excluded — that window is
// microseconds wide, and maintenance callers must be idempotent regardless.
// Daemon /push appends never take this lock at all (they bypass nextSeq).
//
// The returned release func must be called exactly once.
func AcquireHostLock(storeDir, host string) (release func() error, err error) {
	if storeDir == "" {
		return nil, errors.New("storeDir required")
	}
	if err := os.MkdirAll(storeDir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(storeDir, "seq-"+host), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	if err := flockExclusive(f); err != nil {
		_ = f.Close()
		return nil, err
	}
	return func() error {
		defer f.Close()
		return flockRelease(f)
	}, nil
}
