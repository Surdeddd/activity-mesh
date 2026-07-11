package event

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const clockOffsetFile = "clock-offset-ms"

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

func ClockOffsetPath() string {
	dir := StateDir()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, clockOffsetFile)
}

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
