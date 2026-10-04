package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/redact"
)

const contractScopesYAML = `schema_version: 1
scopes:
  - name: live-scope
    status: active
  - name: fading-scope
    status: deprecated
    replaced_by: live-scope
  - name: dead-scope
    status: archived
`

const contractKindsYAML = `schema_version: 1
core:
  - name: note
    description: "note"
    severity_default: P3
`

func sandboxEnv(t *testing.T) (syncDir, storeDir, home string) {
	t.Helper()
	root := t.TempDir()
	syncDir = filepath.Join(root, "sync")
	storeDir = filepath.Join(root, "state")
	home = filepath.Join(root, "home")
	for _, d := range []string{syncDir, storeDir, home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HOME", home)
	t.Setenv("ACTIVITY_MESH_SYNC", syncDir)
	t.Setenv("ACTIVITY_MESH_HOME", storeDir)
	t.Setenv("ACTIVITY_MESH_STATE", filepath.Join(root, "xstate"))
	configPath = ""
	return
}

func captureStdout(t *testing.T, f func() error) (string, error) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	runErr := f()
	_ = w.Close()
	os.Stdout = old
	out, _ := io.ReadAll(r)
	return string(out), runErr
}

func captureStderr(t *testing.T, f func() error) (string, error) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	runErr := f()
	_ = w.Close()
	os.Stderr = old
	out, _ := io.ReadAll(r)
	return string(out), runErr
}

func dbURLAtCapBoundary() (summary, password string) {
	password = "S3cr3tPassw0rd"
	head := "postgres://admin:" + password
	pad := strings.Repeat("word ", 200)[:event.MaxSummaryRunes-2-len(head)] + " "
	return pad + head + "@db.internal:5432/app", password
}

func TestEnforceRegistryLifecycle(t *testing.T) {
	sync := t.TempDir()
	if err := os.WriteFile(filepath.Join(sync, "scopes.yaml"), []byte(contractScopesYAML), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sync, "kinds.yaml"), []byte(contractKindsYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := enforceRegistry(sync, "note", "live-scope"); err != nil {
		t.Fatalf("active scope + core kind must pass: %v", err)
	}
	if err := enforceRegistry(sync, "note", "dead-scope"); err == nil {
		t.Fatal("archived scope must reject new events")
	}
	if err := enforceRegistry(sync, "note", "fading-scope"); err != nil {
		t.Fatalf("deprecated scope must warn but pass: %v", err)
	}
	if err := enforceRegistry(sync, "note", "unknown-scope"); err != nil {
		t.Fatalf("unknown scope must pass (forward-compat): %v", err)
	}
	if err := enforceRegistry(sync, "made-up-kind", "live-scope"); err == nil {
		t.Fatal("unknown bare kind must be rejected when kinds.yaml is present")
	}
	if err := enforceRegistry(sync, "myorg/custom", "live-scope"); err != nil {
		t.Fatalf("namespaced extension kind must pass: %v", err)
	}
}

func TestEnforceRegistryAbsentFilesPass(t *testing.T) {
	if err := enforceRegistry(t.TempDir(), "anything", "anywhere"); err != nil {
		t.Fatalf("missing registries must not block emit: %v", err)
	}
}

func TestEnforceRegistryBrokenYAMLFailsClosed(t *testing.T) {
	cases := []struct{ file, broken string }{
		{"scopes.yaml", "scopes: [\n"},
		{"kinds.yaml", "kinds: [\n"},
	}
	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			syncDir := t.TempDir()
			if err := os.WriteFile(filepath.Join(syncDir, tc.file), []byte(tc.broken), 0o644); err != nil {
				t.Fatal(err)
			}
			err := enforceRegistry(syncDir, "note", "any")
			if err == nil {
				t.Fatalf("a present but unparsable %s must block emit, got no error", tc.file)
			}
			if !strings.Contains(err.Error(), tc.file) {
				t.Fatalf("the error must name %s so the operator knows which registry is broken: %v", tc.file, err)
			}
		})
	}
}

func TestNormalizeSummaryHardCap(t *testing.T) {
	s, tr := event.NormalizeSummary(strings.Repeat("я", 700))
	if !tr {
		t.Fatal("must report truncation")
	}
	if got := len([]rune(s)); got != event.MaxSummaryRunes {
		t.Fatalf("want %d runes, got %d", event.MaxSummaryRunes, got)
	}
	s2, tr2 := event.NormalizeSummary("short")
	if tr2 || s2 != "short" {
		t.Fatalf("short summary must pass through: %q %v", s2, tr2)
	}
}

func TestEmitTruncationBeforeRedactionLeaksPassword(t *testing.T) {
	syncDir, _, _ := sandboxEnv(t)
	summary, password := dbURLAtCapBoundary()
	if red, _ := redact.Apply(summary); strings.Contains(red, password) {
		t.Fatal("precondition: the untruncated summary must be redactable")
	}
	cmd := emitCmd()
	cmd.SetArgs([]string{"--kind", "note", "--scope", "s", "--summary", summary})
	if _, err := captureStdout(t, cmd.Execute); err != nil {
		t.Fatalf("emit: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(syncDir, "events-"+event.HostName()+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), password) {
		t.Fatalf("emit wrote the db password to the shard in plaintext (summary truncated before redaction):\n%s", raw)
	}
}

func TestEmitTruncationWarningFollowsStoredEvent(t *testing.T) {
	shrinks, _ := dbURLAtCapBoundary()
	cases := []struct {
		name    string
		summary string
		want    bool
	}{
		{"redaction inflates past the cap", strings.TrimSpace(strings.Repeat("10.0.0.1 ", 55)), true},
		{"redaction shrinks under the cap", shrinks, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			syncDir, _, _ := sandboxEnv(t)
			cmd := emitCmd()
			cmd.SetArgs([]string{"--kind", "note", "--scope", "s", "--summary", tc.summary})
			stderr, err := captureStderr(t, func() error {
				_, runErr := captureStdout(t, cmd.Execute)
				return runErr
			})
			if err != nil {
				t.Fatalf("emit: %v", err)
			}
			stored := readShard(t, syncDir, event.HostName())
			if len(stored) != 1 || stored[0].Truncated != tc.want {
				t.Fatalf("premise broken: want one stored event with truncated=%v, got %+v", tc.want, stored)
			}
			if warned := strings.Contains(stderr, "summary truncated"); warned != tc.want {
				t.Fatalf("warning printed=%v, want %v (stored truncated=%v): %q", warned, tc.want, stored[0].Truncated, stderr)
			}
		})
	}
}

func TestValidPriority(t *testing.T) {
	for _, ok := range []string{"", "P0", "P1", "P2", "P3"} {
		if !event.ValidPriority(ok) {
			t.Errorf("%q must be valid", ok)
		}
	}
	for _, bad := range []string{"P4", "p1", "high", "0"} {
		if event.ValidPriority(bad) {
			t.Errorf("%q must be invalid", bad)
		}
	}
}
