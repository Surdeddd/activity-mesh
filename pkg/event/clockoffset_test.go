package event

import (
	"os"
	"path/filepath"
	"testing"
)

func writeOffsetFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), clockOffsetFile)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadClockOffsetMS_Present(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    int64
	}{
		{"plain", "33", 33},
		{"negative", "-1250", -1250},
		{"trailing newline", "47\n", 47},
		{"surrounding whitespace", "  912 \n", 912},
		{"zero", "0", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := writeOffsetFile(t, tc.content)
			got, ok := readClockOffsetMS(path)
			if !ok {
				t.Fatalf("readClockOffsetMS(%q) ok=false, want true", tc.content)
			}
			if got != tc.want {
				t.Fatalf("readClockOffsetMS(%q) = %d, want %d", tc.content, got, tc.want)
			}
		})
	}
}

func TestReadClockOffsetMS_Missing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "does-not-exist")
	if ms, ok := readClockOffsetMS(path); ok || ms != 0 {
		t.Fatalf("missing file: got (%d, %v), want (0, false)", ms, ok)
	}
	if ms, ok := readClockOffsetMS(""); ok || ms != 0 {
		t.Fatalf("empty path: got (%d, %v), want (0, false)", ms, ok)
	}
}

func TestReadClockOffsetMS_Garbage(t *testing.T) {
	for _, content := range []string{"", "\n", "not-a-number", "12.5", "12ms", "0x21", "9223372036854775808"} {
		path := writeOffsetFile(t, content)
		if ms, ok := readClockOffsetMS(path); ok || ms != 0 {
			t.Fatalf("garbage %q: got (%d, %v), want (0, false)", content, ms, ok)
		}
	}
}

func TestNewPicksUpCachedOffset(t *testing.T) {
	stateDir := t.TempDir()
	t.Setenv("ACTIVITY_MESH_STATE", stateDir)
	storeDir := t.TempDir()

	ev, err := New(storeDir, "note", "scope:test", "no offset file yet")
	if err != nil {
		t.Fatal(err)
	}
	if ev.ClockOffsetMS != 0 {
		t.Fatalf("no offset file: ClockOffsetMS = %d, want 0", ev.ClockOffsetMS)
	}

	if err := os.WriteFile(filepath.Join(stateDir, clockOffsetFile), []byte("-42\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ev, err = New(storeDir, "note", "scope:test", "offset cached")
	if err != nil {
		t.Fatal(err)
	}
	if ev.ClockOffsetMS != -42 {
		t.Fatalf("cached offset: ClockOffsetMS = %d, want -42", ev.ClockOffsetMS)
	}
}
