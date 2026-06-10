package event

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// clockOffsetFile is the basename of the cached NTP offset inside the
// per-host state dir. It holds a single integer: local_clock - true_clock
// in milliseconds, written by `activity-log clock-sync`.
const clockOffsetFile = "clock-offset-ms"

// StateDir resolves the per-host (non-synced) state directory. It honours
// $ACTIVITY_MESH_STATE — the same convention as health/lib.sh — and falls
// back to ~/.local/state/activity-mesh. Empty string when $HOME is unknown.
func StateDir() string {
	if dir := os.Getenv("ACTIVITY_MESH_STATE"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "state", "activity-mesh")
}

// ClockOffsetPath is the full path of the cached clock offset file.
// Empty string when the state dir cannot be resolved.
func ClockOffsetPath() string {
	dir := StateDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, clockOffsetFile)
}

// readClockOffsetMS reads a cached offset from path. It is deliberately
// fault-tolerant and silent: a missing, empty, or unparsable file simply
// yields ok=false so callers omit the field — never an error or a log line.
func readClockOffsetMS(path string) (ms int64, ok bool) {
	if path == "" {
		return 0, false
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	s := strings.TrimSpace(string(buf))
	if s == "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}
