// refresh-scopes — regenerate the L3 router scopes-cache from the scopes
// registry.
//
// The UserPromptSubmit router (hooks/user-prompt-router.sh) matches prompt
// text against $ACTIVITY_MESH_CONFIG/scopes-cache (default
// ~/.config/activity-mesh/scopes-cache, one bare scope name per line). A
// hand-maintained cache rots silently when scopes change, so this
// subcommand derives it from the registry: active scopes only, minus those
// marked `router: false` (scope names colliding with the router's
// agent-intent names double-filter --scope+--agent to empty — see RB-7).
//
// Registry resolution order:
//
//  1. --registry PATH              explicit override
//  2. <sync_dir>/scopes.yaml       canonical live copy (Syncthing-replicated;
//                                  same location health/checks/schema-drift.sh
//                                  reads). sync_dir comes from config.json.
//  3. ./registries/scopes.yaml     repo-checkout seed fallback
//
// On read/parse failure: clear error, non-zero exit, existing cache left
// untouched. The cache is written atomically (temp file + rename).
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/Surdeddd/activity-mesh/pkg/registry"
)

func refreshScopesCmd() *cobra.Command {
	var (
		regArg string
		dryRun bool
	)
	cmd := &cobra.Command{
		Use:   "refresh-scopes",
		Short: "Regenerate the L3 router scopes-cache from the scopes registry.",
		Long: "Reads scopes.yaml (--registry, else <sync>/scopes.yaml, else\n" +
			"./registries/scopes.yaml) and atomically rewrites the router's\n" +
			"scopes-cache ($ACTIVITY_MESH_CONFIG or ~/.config/activity-mesh)\n" +
			"with active scopes only, minus those marked `router: false`.\n" +
			"On registry read/parse failure the existing cache is left untouched.",
		RunE: func(cmd *cobra.Command, args []string) error {
			return refreshScopes(regArg, dryRun, os.Stdout)
		},
	}
	cmd.Flags().StringVar(&regArg, "registry", "", "path to scopes.yaml (default: <sync>/scopes.yaml, then ./registries/scopes.yaml)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the would-be cache content without writing")
	return cmd
}

// routerConfigDir resolves the directory the router hook reads its cache
// from — $ACTIVITY_MESH_CONFIG (the same env hooks/user-prompt-router.sh
// honours) with ~/.config/activity-mesh as the default.
func routerConfigDir() (string, error) {
	if dir := os.Getenv("ACTIVITY_MESH_CONFIG"); dir != "" {
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot resolve config dir (no $ACTIVITY_MESH_CONFIG and no home dir): %w", err)
	}
	return filepath.Join(home, ".config", "activity-mesh"), nil
}

// resolveScopesRegistry picks the scopes.yaml to read. An explicit path wins
// unconditionally (missing file surfaces as a read error with that path);
// otherwise the first existing candidate is used.
func resolveScopesRegistry(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	var candidates []string
	if cfg, err := loadConfig(); err == nil {
		candidates = append(candidates, filepath.Join(cfg.SyncDir, "scopes.yaml"))
	}
	candidates = append(candidates, filepath.Join("registries", "scopes.yaml"))
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c, nil
		}
	}
	return "", fmt.Errorf("scopes registry not found (looked at: %s) — publish scopes.yaml to the sync dir or pass --registry",
		strings.Join(candidates, ", "))
}

// refreshScopes is the testable core: resolve → load/validate → render →
// atomic write (or dry-run print). Any error before the final rename leaves
// the existing cache byte-identical.
func refreshScopes(regArg string, dryRun bool, out io.Writer) error {
	regPath, err := resolveScopesRegistry(regArg)
	if err != nil {
		return err
	}
	reg, err := registry.LoadScopesFile(regPath)
	if err != nil {
		return fmt.Errorf("scopes registry %s: %w (existing cache left untouched)", regPath, err)
	}
	include := reg.RouterScopes()
	excluded := len(reg.ActiveScopes()) - len(include)

	var b strings.Builder
	for _, s := range include {
		b.WriteString(s.Name)
		b.WriteByte('\n')
	}

	cfgDir, err := routerConfigDir()
	if err != nil {
		return err
	}
	cachePath := filepath.Join(cfgDir, "scopes-cache")

	if dryRun {
		fmt.Fprint(out, b.String())
		fmt.Fprintf(out, "dry-run: %d scopes would be written, %d excluded (router: false) → %s (registry: %s)\n",
			len(include), excluded, cachePath, regPath)
		return nil
	}
	if err := atomicWriteFile(cachePath, []byte(b.String())); err != nil {
		return fmt.Errorf("write %s: %w", cachePath, err)
	}
	fmt.Fprintf(out, "scopes-cache: %d scopes written, %d excluded (router: false) → %s (registry: %s)\n",
		len(include), excluded, cachePath, regPath)
	return nil
}
