package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const agentsYAML = `schema_version: 1
agents:
  - id: hermes
    status: active
    aliases: [hermes, хермес]
  - id: claude-mac
    status: active
    aliases: [claude-mac, клод-mac]
    weak_aliases: [claude, клод]
  - id: no-alias-agent
    status: active
  - id: reina
    status: archived
    aliases: [reina]
`

func TestRefreshAgents_WritesCacheFromRegistry(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ACTIVITY_MESH_CONFIG", dir)
	reg := writeFile(t, filepath.Join(dir, "agents.yaml"), agentsYAML)

	var out bytes.Buffer
	if err := refreshAgents(reg, false, &out); err != nil {
		t.Fatalf("refreshAgents: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "agents-cache"))
	if err != nil {
		t.Fatal(err)
	}
	got := string(raw)

	wantLines := map[string]bool{
		"hermes\thermes,хермес\t":                      true,
		"claude-mac\tclaude-mac,клод-mac\tclaude,клод": true,
		"no-alias-agent\tno-alias-agent\t":             true,
	}
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != len(wantLines) {
		t.Fatalf("want %d lines, got %d: %q", len(wantLines), len(lines), got)
	}
	for _, l := range lines {
		if !wantLines[l] {
			t.Errorf("unexpected cache line: %q", l)
		}
	}
	if strings.Contains(got, "reina") {
		t.Error("archived agent leaked into cache")
	}
}

func TestRefreshAgents_DryRunWritesNothing(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ACTIVITY_MESH_CONFIG", dir)
	reg := writeFile(t, filepath.Join(dir, "agents.yaml"), agentsYAML)

	var out bytes.Buffer
	if err := refreshAgents(reg, true, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "agents-cache")); err == nil {
		t.Error("dry-run wrote the cache file")
	}
	if !strings.Contains(out.String(), "dry-run") {
		t.Errorf("expected dry-run marker in output: %q", out.String())
	}
}
