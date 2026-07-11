package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Surdeddd/activity-mesh/pkg/event"
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

func TestEnforceRegistryBrokenYAMLPasses(t *testing.T) {
	sync := t.TempDir()
	if err := os.WriteFile(filepath.Join(sync, "scopes.yaml"), []byte("::: not yaml"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := enforceRegistry(sync, "note", "any"); err != nil {
		t.Fatalf("broken registry must warn, not block emit: %v", err)
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
