package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The CLI must honour the same path overrides the daemon does. Without this,
// ACTIVITY_MESH_SYNC points the daemon at one shard dir while the CLI keeps
// writing to another — and no sandboxed install is possible at all.

func writeConfig(t *testing.T, path, syncDir, storeDir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	buf, err := json.Marshal(config{SyncDir: syncDir, StoreDir: storeDir})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadConfigEnvOverridesDirs(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	writeConfig(t, cfgPath, filepath.Join(dir, "from-config"), filepath.Join(dir, "store-from-config"))

	envSync := filepath.Join(dir, "from-env")
	envHome := filepath.Join(dir, "store-from-env")
	t.Setenv("ACTIVITY_MESH_SYNC", envSync)
	t.Setenv("ACTIVITY_MESH_HOME", envHome)

	configPath = cfgPath
	t.Cleanup(func() { configPath = "" })

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.SyncDir != envSync {
		t.Errorf("SyncDir = %q, want env override %q", cfg.SyncDir, envSync)
	}
	if cfg.StoreDir != envHome {
		t.Errorf("StoreDir = %q, want env override %q", cfg.StoreDir, envHome)
	}
}

func TestLoadConfigWithoutEnvKeepsConfigValues(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")
	wantSync := filepath.Join(dir, "from-config")
	wantStore := filepath.Join(dir, "store-from-config")
	writeConfig(t, cfgPath, wantSync, wantStore)

	t.Setenv("ACTIVITY_MESH_SYNC", "")
	t.Setenv("ACTIVITY_MESH_HOME", "")

	configPath = cfgPath
	t.Cleanup(func() { configPath = "" })

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.SyncDir != wantSync || cfg.StoreDir != wantStore {
		t.Errorf("got %q/%q, want unchanged %q/%q", cfg.SyncDir, cfg.StoreDir, wantSync, wantStore)
	}
}

func TestDefaultConfigPathHonoursHomeEnv(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ACTIVITY_MESH_HOME", dir)

	got, err := defaultConfigPath()
	if err != nil {
		t.Fatalf("defaultConfigPath: %v", err)
	}
	if want := filepath.Join(dir, "config.json"); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// Regression for the trap that started this: `init` with the env set wrote to
// the real ~/Sync/activity anyway, polluting a live shard.
func TestInitHonoursEnvAndNeverTouchesHome(t *testing.T) {
	sandbox := t.TempDir()
	fakeHome := t.TempDir()

	t.Setenv("HOME", fakeHome)
	t.Setenv("ACTIVITY_MESH_HOME", filepath.Join(sandbox, "state"))
	t.Setenv("ACTIVITY_MESH_SYNC", filepath.Join(sandbox, "sync"))

	configPath = ""
	cmd := initCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("init: %v", err)
	}

	cfgPath := filepath.Join(sandbox, "state", "config.json")
	buf, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("config not written to sandbox: %v", err)
	}
	var c config
	if err := json.Unmarshal(buf, &c); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(sandbox, "sync"); c.SyncDir != want {
		t.Errorf("SyncDir = %q, want %q", c.SyncDir, want)
	}

	if _, err := os.Stat(filepath.Join(fakeHome, "Sync")); !os.IsNotExist(err) {
		t.Errorf("init created %s/Sync despite ACTIVITY_MESH_SYNC being set", fakeHome)
	}
	if _, err := os.Stat(filepath.Join(fakeHome, defaultStateDir)); !os.IsNotExist(err) {
		t.Errorf("init created %s/%s despite ACTIVITY_MESH_HOME being set", fakeHome, defaultStateDir)
	}
}
