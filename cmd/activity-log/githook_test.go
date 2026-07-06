package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallGitHook_FreshAndIdempotent(t *testing.T) {
	repo := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repo, ".git", "hooks"), 0o755); err != nil {
		t.Fatal(err)
	}
	hookPath := filepath.Join(repo, ".git", "hooks", "post-commit")

	cmd := installGitHookCmd()
	cmd.SetArgs([]string{"--repo", repo})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	b, err := os.ReadFile(hookPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), hookMarker) {
		t.Fatalf("hook marker missing: %s", b)
	}
	fi, _ := os.Stat(hookPath)
	if fi.Mode()&0o111 == 0 {
		t.Error("hook is not executable")
	}

	// second run must be a no-op (no duplicate snippet)
	cmd2 := installGitHookCmd()
	cmd2.SetArgs([]string{"--repo", repo})
	if err := cmd2.Execute(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	b2, _ := os.ReadFile(hookPath)
	if strings.Count(string(b2), hookMarker) != 1 {
		t.Errorf("marker appears %d times, want 1 (idempotency broken)", strings.Count(string(b2), hookMarker))
	}
}

func TestInstallGitHook_AppendsToExisting(t *testing.T) {
	repo := t.TempDir()
	hooksDir := filepath.Join(repo, ".git", "hooks")
	if err := os.MkdirAll(hooksDir, 0o755); err != nil {
		t.Fatal(err)
	}
	hookPath := filepath.Join(hooksDir, "post-commit")
	if err := os.WriteFile(hookPath, []byte("#!/bin/sh\necho existing-hook\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := installGitHookCmd()
	cmd.SetArgs([]string{"--repo", repo})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(hookPath)
	if !strings.Contains(string(b), "existing-hook") {
		t.Error("existing hook body was clobbered")
	}
	if !strings.Contains(string(b), hookMarker) {
		t.Error("activity-mesh snippet not appended")
	}
}

func TestInstallGitHook_RejectsNonRepo(t *testing.T) {
	dir := t.TempDir() // no .git
	cmd := installGitHookCmd()
	cmd.SetArgs([]string{"--repo", dir})
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error for non-git dir")
	}
}
