// install-git-hook — wire a repo's post-commit hook to emit a `project`
// event per commit. Documented as an auto-capture source since v1 but never
// shippable before; this makes it one command.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

// postCommitHook is the script written to .git/hooks/post-commit. It resolves
// the activity-log binary the same way the read hooks do (PATH →
// ~/.local/bin), derives the scope from the repo directory name, and emits a
// one-line `project` event. Best-effort: a missing binary is a silent no-op,
// never a failed commit.
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
			hooksDir := filepath.Join(root, ".git", "hooks")
			if fi, err := os.Stat(filepath.Join(root, ".git")); err != nil || !fi.IsDir() {
				return fmt.Errorf("%s is not a git repo (no .git dir)", root)
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
				// Append our snippet (minus its shebang) to the existing hook.
				snippet := "\n# --- activity-mesh (appended) ---\n" +
					strings.TrimPrefix(postCommitHook, "#!/bin/sh\n")
				merged := append(existing, []byte(snippet)...)
				if err := os.WriteFile(hookPath, merged, 0o755); err != nil {
					return err
				}
			}
			fmt.Printf("installed activity-mesh post-commit hook → %s\n", hookPath)
			return nil
		},
	}
	cmd.Flags().StringVar(&repo, "repo", "", "target repo path (default: current repo)")
	return cmd
}
