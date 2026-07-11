package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeCfg(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "watcher.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadConfigRejectsUnknownOp(t *testing.T) {
	p := writeCfg(t, `activity_log_bin: /bin/echo
sources:
  - name: s
    path: /tmp
    op: created
    emit:
      kind: note
      scope: activity-mesh
      summary_template: "x"
`)
	if _, err := loadConfig(p); err == nil {
		t.Fatal("expected unknown-op rejection")
	}
}

func TestLoadConfigRejectsNonBoolRecursive(t *testing.T) {
	p := writeCfg(t, `activity_log_bin: /bin/echo
sources:
  - name: s
    path: /tmp
    op: create
    recursive: yes
    emit:
      kind: note
      scope: activity-mesh
      summary_template: "x"
`)
	if _, err := loadConfig(p); err == nil {
		t.Fatal("expected non-bool recursive rejection")
	}
}

func TestLoadConfigAcceptsValidOps(t *testing.T) {
	for _, op := range []string{"create", "modify", "delete", "create_or_modify", "any"} {
		p := writeCfg(t, `activity_log_bin: /bin/echo
sources:
  - name: s
    path: /tmp
    op: `+op+`
    recursive: false
    emit:
      kind: note
      scope: activity-mesh
      summary_template: "x"
`)
		if _, err := loadConfig(p); err != nil {
			t.Errorf("op %q: unexpected error %v", op, err)
		}
	}
}
