package event

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func HostName() string {
	host, _ := os.Hostname()
	host = strings.TrimSpace(host)
	if host == "" {
		host = "unknown"
	}
	return host
}

type HostLock struct {
	f *os.File
}

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

func (h *HostLock) Release() error {
	defer h.f.Close()
	return flockRelease(h.f)
}

func (h *HostLock) NextSeq() (uint64, error) {
	if _, err := h.f.Seek(0, io.SeekStart); err != nil {
		return 0, err
	}
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
