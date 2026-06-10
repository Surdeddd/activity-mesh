package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeFile is a tiny helper for fixture files.
func writeFile(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// cacheDir points ACTIVITY_MESH_CONFIG (the env the router hook honours) at
// a temp dir and returns the scopes-cache path inside it.
func cacheDir(t *testing.T) (dir, cachePath string) {
	t.Helper()
	dir = t.TempDir()
	t.Setenv("ACTIVITY_MESH_CONFIG", dir)
	return dir, filepath.Join(dir, "scopes-cache")
}

const mixedScopesYAML = `schema_version: 1
scopes:
  - name: zeta
    status: active
  - name: alpha
    status: active
    router: true
  - name: hermes
    status: active
    router: false
  - name: old-thing
    status: archived
  - name: meh
    status: deprecated
`

// TestRefreshScopes_WritesCacheExcludingRouterFalse — active scopes minus
// router:false land in the cache (sorted, one per line), a pre-existing
// stale cache is fully replaced, and no temp residue is left behind.
func TestRefreshScopes_WritesCacheExcludingRouterFalse(t *testing.T) {
	dir, cachePath := cacheDir(t)
	writeFile(t, cachePath, "stale-entry\nleftover\n") // must be replaced wholesale
	reg := writeFile(t, filepath.Join(t.TempDir(), "scopes.yaml"), mixedScopesYAML)

	var out bytes.Buffer
	if err := refreshScopes(reg, false, &out); err != nil {
		t.Fatalf("refreshScopes: %v", err)
	}
	got, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	if want := "alpha\nzeta\n"; string(got) != want {
		t.Errorf("cache = %q, want %q", got, want)
	}
	if !strings.Contains(out.String(), "2 scopes written, 1 excluded") {
		t.Errorf("summary line missing counts: %q", out.String())
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "scopes-cache" {
		t.Errorf("config dir should hold only scopes-cache (no temp residue), got %v", entries)
	}
}

// TestRefreshScopes_FailureKeepsOldCache — malformed YAML and a future
// schema_version must both error out without touching the existing cache.
func TestRefreshScopes_FailureKeepsOldCache(t *testing.T) {
	for name, bad := range map[string]string{
		"malformed":      "schema_version: 1\nscopes: [",
		"future-schema":  "schema_version: 99\nscopes: []\n",
		"invalid-status": "schema_version: 1\nscopes:\n  - name: foo\n    status: actve\n",
	} {
		t.Run(name, func(t *testing.T) {
			_, cachePath := cacheDir(t)
			const keep = "keep-me\nand-me\n"
			writeFile(t, cachePath, keep)
			reg := writeFile(t, filepath.Join(t.TempDir(), "scopes.yaml"), bad)

			var out bytes.Buffer
			if err := refreshScopes(reg, false, &out); err == nil {
				t.Fatalf("expected error for %s registry", name)
			}
			got, err := os.ReadFile(cachePath)
			if err != nil {
				t.Fatalf("read cache: %v", err)
			}
			if string(got) != keep {
				t.Errorf("cache modified on failure: %q, want %q", got, keep)
			}
		})
	}
}

// TestRefreshScopes_MissingRegistry — explicit path to a nonexistent file is
// a clear error; the cache stays untouched.
func TestRefreshScopes_MissingRegistry(t *testing.T) {
	_, cachePath := cacheDir(t)
	const keep = "keep-me\n"
	writeFile(t, cachePath, keep)

	var out bytes.Buffer
	err := refreshScopes(filepath.Join(t.TempDir(), "nope.yaml"), false, &out)
	if err == nil {
		t.Fatalf("expected error for missing registry")
	}
	if got, _ := os.ReadFile(cachePath); string(got) != keep {
		t.Errorf("cache modified on missing registry: %q", got)
	}
}

// TestRefreshScopes_DryRun — prints the would-be content + summary, writes
// nothing.
func TestRefreshScopes_DryRun(t *testing.T) {
	_, cachePath := cacheDir(t)
	reg := writeFile(t, filepath.Join(t.TempDir(), "scopes.yaml"), mixedScopesYAML)

	var out bytes.Buffer
	if err := refreshScopes(reg, true, &out); err != nil {
		t.Fatalf("refreshScopes --dry-run: %v", err)
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Errorf("dry-run must not create the cache (stat err=%v)", err)
	}
	if !strings.HasPrefix(out.String(), "alpha\nzeta\n") || !strings.Contains(out.String(), "dry-run:") {
		t.Errorf("unexpected dry-run output: %q", out.String())
	}
}

// TestResolveScopesRegistry_PrefersSyncLiveCopy — without --registry the
// canonical live copy <sync>/scopes.yaml (sync dir from config.json) wins.
func TestResolveScopesRegistry_PrefersSyncLiveCopy(t *testing.T) {
	storeDir, syncDir := setupTempEnv(t)
	live := writeFile(t, filepath.Join(syncDir, "scopes.yaml"), mixedScopesYAML)

	cfgPath := filepath.Join(storeDir, "config.json")
	if err := saveConfig(cfgPath, &config{SyncDir: syncDir, StoreDir: storeDir}); err != nil {
		t.Fatal(err)
	}
	prev := configPath
	configPath = cfgPath
	t.Cleanup(func() { configPath = prev })

	got, err := resolveScopesRegistry("")
	if err != nil {
		t.Fatalf("resolveScopesRegistry: %v", err)
	}
	if got != live {
		t.Errorf("resolved %q, want live sync copy %q", got, live)
	}
}
