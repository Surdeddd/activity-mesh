package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

const postCommitHook = `#!/bin/sh
# activity-mesh post-commit hook (installed by 'activity-log install-git-hook').
BIN="${ACTIVITY_MESH_BIN:-$(command -v activity-log 2>/dev/null || true)}"
[ -z "$BIN" ] && [ -x "$HOME/.local/bin/activity-log" ] && BIN="$HOME/.local/bin/activity-log"
[ -z "$BIN" ] && exit 0
repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
sha=$(git rev-parse --short HEAD 2>/dev/null)
subject=$(git log -1 --pretty=%s 2>/dev/null)
[ -z "$sha" ] && exit 0
"$BIN" emit --kind project --scope "project:${repo:-unknown}" \
    --summary "${subject:-commit} (${sha})" --ref "git://${sha}" >/dev/null 2>&1 || true
exit 0
`

const hookMarker = "activity-mesh post-commit hook"

func installGitHookCmd() *cobra.Command {
	var repo string
	cmd := &cobra.Command{
		Use:   "install-git-hook",
		Short: "Install a post-commit hook that emits a project event per commit.",
		Long: "Writes .git/hooks/post-commit in the target repo (default: the\n" +
			"current repo). If a post-commit hook already exists, the activity-mesh\n" +
			"snippet is appended once (idempotent). Each commit then emits a\n" +
			"`project` event with the commit subject, short SHA, and a git:// ref.",
		RunE: func(cmd *cobra.Command, args []string) error {
			root := repo
			if root == "" {
				out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
				if err != nil {
					return errors.New("not inside a git repo — pass --repo PATH")
				}
				root = strings.TrimSpace(string(out))
			}
			hooksDir, err := resolveHooksDir(root)
			if err != nil {
				return err
			}
			if err := os.MkdirAll(hooksDir, 0o755); err != nil {
				return err
			}
			hookPath := filepath.Join(hooksDir, "post-commit")
			existing, err := os.ReadFile(hookPath)
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			if strings.Contains(string(existing), hookMarker) {
				fmt.Printf("post-commit hook already wired in %s — nothing to do\n", root)
				return nil
			}
			if len(existing) == 0 {
				if err := os.WriteFile(hookPath, []byte(postCommitHook), 0o755); err != nil {
					return err
				}
			} else {
				// Keep a one-time copy: this rewrites a file the user wrote by hand.
				backup := hookPath + ".pre-activity-mesh.bak"
				if _, serr := os.Stat(backup); errors.Is(serr, os.ErrNotExist) {
					if err := os.WriteFile(backup, existing, 0o644); err != nil {
						return fmt.Errorf("back up existing hook: %w", err)
					}
					fmt.Printf("backed up existing hook → %s\n", backup)
				}
				snippet := "\n# --- activity-mesh (appended) ---\n" +
					strings.TrimPrefix(postCommitHook, "#!/bin/sh\n")
				merged := append(existing, []byte(snippet)...)
				if err := os.WriteFile(hookPath, merged, 0o755); err != nil {
					return err
				}
				if bytes.Contains(existing, []byte("\nexit ")) {
					fmt.Fprintln(os.Stderr, "warn: the existing hook contains an `exit` — the appended snippet may never run; move it up by hand")
				}
			}
			// os.WriteFile ignores the mode for a file that already existed, so a
			// hand-made 0644 hook would stay silently inert after the append.
			if fi, serr := os.Stat(hookPath); serr == nil && fi.Mode()&0o111 == 0 {
				if err := os.Chmod(hookPath, fi.Mode()|0o755); err != nil {
					return fmt.Errorf("make hook executable: %w", err)
				}
			}
			fmt.Printf("installed activity-mesh post-commit hook → %s\n", hookPath)
			return nil
		},
	}
	cmd.Flags().StringVar(&repo, "repo", "", "target repo path (default: current repo)")
	return cmd
}

// resolveHooksDir asks git where hooks actually live. Hardcoding <root>/.git/hooks
// hard-fails in worktrees and submodules (.git is a file there) and silently
// no-ops when core.hooksPath is set — husky and lefthook both set it, and the
// command would report success while git never reads the file it wrote.
func resolveHooksDir(root string) (string, error) {
	out, err := exec.Command("git", "-C", root, "rev-parse", "--git-path", "hooks").Output()
	if err != nil {
		if fi, serr := os.Stat(filepath.Join(root, ".git")); serr != nil || !fi.IsDir() {
			return "", fmt.Errorf("%s is not a git repo (git rev-parse failed: %v)", root, err)
		}
		return filepath.Join(root, ".git", "hooks"), nil
	}
	dir := strings.TrimSpace(string(out))
	if dir == "" {
		return filepath.Join(root, ".git", "hooks"), nil
	}
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(root, dir)
	}
	return dir, nil
}
