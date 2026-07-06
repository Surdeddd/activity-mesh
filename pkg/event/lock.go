// Per-host identity + advisory locking shared by the emit path and shard
// maintenance (compaction, daemon /push).
package event

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
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

// HostLock is the exclusive per-host advisory lock (flock on
// storeDir/seq-<host>). Every writer holds it for the WHOLE
// seq-allocate → marshal → shard-append sequence, and compaction holds it
// across its read → rewrite → rename cycle — so an append can never land in
// the middle of a rewrite and be destroyed.
type HostLock struct {
	f *os.File
}

// AcquireHostLock takes the per-host lock. The returned lock must be
// released exactly once via Release.
func AcquireHostLock(storeDir, host string) (*HostLock, error) {
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
	return &HostLock{f: f}, nil
}

// Release unlocks and closes the underlying handle. Safe to call once.
func (h *HostLock) Release() error {
	defer h.f.Close()
	return flockRelease(h.f)
}

// NextSeq increments and persists the monotonic counter stored in the locked
// file. Crash-safe: the counter only grows, so the new decimal string is
// never shorter than the old one and a plain WriteAt(0) can never leave a
// stale tail behind — there is no truncate window that could zero the file.
func (h *HostLock) NextSeq() (uint64, error) {
	if _, err := h.f.Seek(0, io.SeekStart); err != nil {
		return 0, err
	}
	// Read via the locked handle, not a fresh os.ReadFile(path): on Windows
	// LockFileEx is a mandatory byte-range lock, so a second handle reading
	// the locked region fails. The handle holding the lock can always read.
	buf, err := io.ReadAll(h.f)
	if err != nil {
		return 0, err
	}
	var current uint64
	if s := strings.TrimSpace(string(buf)); s != "" {
		if n, perr := strconv.ParseUint(s, 10, 64); perr == nil {
			current = n
		}
	}
	current++
	out := []byte(strconv.FormatUint(current, 10) + "\n")
	if _, err := h.f.WriteAt(out, 0); err != nil {
		return 0, err
	}
	if len(out) < len(buf) { // only possible after hand-editing the file
		if err := h.f.Truncate(int64(len(out))); err != nil {
			return 0, err
		}
	}
	if err := h.f.Sync(); err != nil {
		return 0, err
	}
	return current, nil
}
