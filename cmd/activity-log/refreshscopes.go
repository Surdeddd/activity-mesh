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
		regArg    string
		agentsArg string
		dryRun    bool
	)
	cmd := &cobra.Command{
		Use:     "refresh-caches",
		Aliases: []string{"refresh-scopes"}, // pre-0.3.0 name; heartbeat cron jobs may still call it
		Short:   "Regenerate the L3 router caches (scopes-cache + agents-cache) from the registries.",
		Long: "Reads scopes.yaml and agents.yaml (--registry/--agents-registry, else\n" +
			"<sync>/*.yaml, else ./registries/*.yaml) and atomically rewrites the\n" +
			"router's scopes-cache and agents-cache ($ACTIVITY_MESH_CONFIG or\n" +
			"~/.config/activity-mesh). Scopes: active only, minus `router: false`.\n" +
			"Agents: active only, with their aliases and weak-aliases.\n" +
			"On registry read/parse failure the existing caches are left untouched.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := refreshScopes(regArg, dryRun, os.Stdout); err != nil {
				return err
			}
			return refreshAgents(agentsArg, dryRun, os.Stdout)
		},
	}
	cmd.Flags().StringVar(&regArg, "registry", "", "path to scopes.yaml (default: <sync>/scopes.yaml, then ./registries/scopes.yaml)")
	cmd.Flags().StringVar(&agentsArg, "agents-registry", "", "path to agents.yaml (default: <sync>/agents.yaml, then ./registries/agents.yaml)")
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

// resolveRegistryFile picks a registry YAML to read. An explicit path wins
// unconditionally (missing file surfaces as a read error with that path);
// otherwise the first existing candidate is used.
func resolveRegistryFile(explicit, base string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	var candidates []string
	if cfg, err := loadConfig(); err == nil {
		candidates = append(candidates, filepath.Join(cfg.SyncDir, base))
	}
	candidates = append(candidates, filepath.Join("registries", base))
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c, nil
		}
	}
	return "", fmt.Errorf("%s registry not found (looked at: %s) — publish %s to the sync dir or pass the registry flag",
		base, strings.Join(candidates, ", "), base)
}

// refreshScopes is the testable core: resolve → load/validate → render →
// atomic write (or dry-run print). Any error before the final rename leaves
// the existing cache byte-identical.
func refreshScopes(regArg string, dryRun bool, out io.Writer) error {
	regPath, err := resolveRegistryFile(regArg, "scopes.yaml")
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

// refreshAgents renders the router's agents-cache from agents.yaml. One line
// per active agent, tab-separated:
//
//	<id>\t<alias1,alias2,...>\t<weak1,weak2,...>
//
// Aliases are matched as lowercase substrings of the prompt by the router; a
// strong-alias match may create an agent intent, a weak-alias match only
// qualifies an existing one. All tokens are lowercased here so the router
// does no per-prompt normalisation work.
func refreshAgents(regArg string, dryRun bool, out io.Writer) error {
	regPath, err := resolveRegistryFile(regArg, "agents.yaml")
	if err != nil {
		return err
	}
	reg, err := registry.LoadAgentsFile(regPath)
	if err != nil {
		return fmt.Errorf("agents registry %s: %w (existing cache left untouched)", regPath, err)
	}
	agents := reg.ActiveAgents()

	joinLower := func(ss []string) string {
		outs := make([]string, 0, len(ss))
		for _, s := range ss {
			if s = strings.ToLower(strings.TrimSpace(s)); s != "" {
				outs = append(outs, s)
			}
		}
		return strings.Join(outs, ",")
	}
	var b strings.Builder
	written := 0
	for _, a := range agents {
		aliases := joinLower(a.Aliases)
		if aliases == "" {
			aliases = strings.ToLower(a.ID) // an agent is always matchable by its own id
		}
		fmt.Fprintf(&b, "%s\t%s\t%s\n", a.ID, aliases, joinLower(a.WeakAliases))
		written++
	}

	cfgDir, err := routerConfigDir()
	if err != nil {
		return err
	}
	cachePath := filepath.Join(cfgDir, "agents-cache")

	if dryRun {
		fmt.Fprint(out, b.String())
		fmt.Fprintf(out, "dry-run: %d agents would be written → %s (registry: %s)\n", written, cachePath, regPath)
		return nil
	}
	if err := atomicWriteFile(cachePath, []byte(b.String())); err != nil {
		return fmt.Errorf("write %s: %w", cachePath, err)
	}
	fmt.Fprintf(out, "agents-cache: %d agents written → %s (registry: %s)\n", written, cachePath, regPath)
	return nil
}
