package shard

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

var hostRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

var ErrBadHost = errors.New("invalid host label")

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

func Path(syncDir, host string) (string, error) {
	if !ValidHost(host) {
		return "", fmt.Errorf("%w: %q", ErrBadHost, host)
	}
	return filepath.Join(syncDir, "events-"+host+".jsonl"), nil
}

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
	// A NUL last byte is a torn tail, not an empty file — treating the two the
	// same skipped the separator and glued the next event onto the broken line.
	if tail, nonEmpty, err := lastByte(target); err == nil && nonEmpty && tail != '\n' {
		buf = append(buf, '\n')
	}
	buf = append(buf, line...)
	buf = append(buf, '\n')
	if _, err := f.Write(buf); err != nil {
		return err
	}
	return f.Sync()
}

// lastByte reports the file's final byte and whether the file had any content
// at all — the two must stay distinguishable, since a NUL byte is a legitimate
// (if corrupt) last byte.
func lastByte(path string) (b byte, nonEmpty bool, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return 0, false, err
	}
	if fi.Size() == 0 {
		return 0, false, nil
	}
	one := make([]byte, 1)
	if _, err := f.ReadAt(one, fi.Size()-1); err != nil {
		return 0, false, err
	}
	return one[0], true, nil
}
