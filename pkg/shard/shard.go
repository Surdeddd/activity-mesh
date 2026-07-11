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
