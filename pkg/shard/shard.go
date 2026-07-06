// Package shard owns the single shard-append primitive shared by every
// writer (CLI emit, daemon /push). The system's core guarantees — one
// writer per events-<host>.jsonl, torn-tail self-healing, durable appends —
// live here and nowhere else.
package shard

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// hostRe restricts shard host labels to a safe filename alphabet. Anything
// else (path separators, "..", empty) must be rejected before the label is
// spliced into a filesystem path.
var hostRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// ErrBadHost is returned when a host label fails validation.
var ErrBadHost = errors.New("invalid host label")

// ValidHost reports whether host is safe to embed in a shard filename.
func ValidHost(host string) bool {
	return hostRe.MatchString(host) && !containsDotDot(host)
}

func containsDotDot(s string) bool {
	for i := 0; i+1 < len(s); i++ {
		if s[i] == '.' && s[i+1] == '.' {
			return true
		}
	}
	return false
}

// Path returns the shard path for host inside syncDir, rejecting host labels
// that could escape the directory.
func Path(syncDir, host string) (string, error) {
	if !ValidHost(host) {
		return "", fmt.Errorf("%w: %q", ErrBadHost, host)
	}
	return filepath.Join(syncDir, "events-"+host+".jsonl"), nil
}

// AppendLocked appends line+"\n" to the host's shard with O_APPEND and
// fsync. The caller MUST hold the per-host lock (event.AcquireHostLock)
// for the whole call — that is what serialises appends against compaction's
// read-rewrite-rename cycle.
//
// Self-healing: if the shard currently ends mid-line (a torn tail from a
// crashed writer — compaction deliberately preserves such tails), a leading
// newline is written first so this event never glues onto the partial line.
func AppendLocked(syncDir, host string, line []byte) error {
	target, err := Path(syncDir, host)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(syncDir, 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(target, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	buf := make([]byte, 0, len(line)+2)
	if tail, err := lastByte(target); err == nil && tail != 0 && tail != '\n' {
		buf = append(buf, '\n')
	}
	buf = append(buf, line...)
	buf = append(buf, '\n')
	if _, err := f.Write(buf); err != nil {
		return err
	}
	return f.Sync()
}

// lastByte returns the final byte of the file at path, or 0 for an empty or
// missing file.
func lastByte(path string) (byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.Size() == 0 {
		return 0, err
	}
	b := make([]byte, 1)
	if _, err := f.ReadAt(b, fi.Size()-1); err != nil {
		return 0, err
	}
	return b[0], nil
}
