// redact — apply the tier-1/2 redaction pipeline to arbitrary text (`--stdin`,
// the contract hooks/secret-redactor.sh depends on) or re-apply it to this
// host's existing shard (`redact-shard`) to scrub leaks that predate a rule
// change (e.g. the per-host home path that a hardcoded username never matched).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/Surdeddd/activity-mesh/pkg/event"
	"github.com/Surdeddd/activity-mesh/pkg/redact"
)

func redactCmd() *cobra.Command {
	var stdin bool
	cmd := &cobra.Command{
		Use:   "redact",
		Short: "Redact secrets/PII from text on stdin (idempotent), writing to stdout.",
		Long: "Reads stdin, applies the tier-1 regex pack + tier-2 entropy heuristic,\n" +
			"and writes the redacted text to stdout. Idempotent: already-redacted\n" +
			"text passes through unchanged. This is the contract hooks/\n" +
			"secret-redactor.sh shells out to before persisting agent output.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if !stdin {
				return fmt.Errorf("--stdin is required (only stdin input is supported)")
			}
			in, err := io.ReadAll(os.Stdin)
			if err != nil {
				return err
			}
			out, _ := redact.Apply(string(in))
			_, err = os.Stdout.WriteString(out)
			return err
		},
	}
	cmd.Flags().BoolVar(&stdin, "stdin", false, "read text from stdin (required)")
	return cmd
}

func redactShardCmd() *cobra.Command {
	var (
		dryRun  bool
		syncArg string
	)
	cmd := &cobra.Command{
		Use:   "redact-shard",
		Short: "Re-apply redaction to this host's existing shard (scrubs pre-rule-change leaks).",
		Long: "Walks this host's events-<host>.jsonl, re-runs the current redaction\n" +
			"rules over every event, and atomically rewrites the shard when any\n" +
			"event changed — under the same per-host lock emit/compact use, so it\n" +
			"never races an append. Malformed/blank lines are preserved verbatim.\n" +
			"Only this host's shard is touched (single-writer invariant). Use after\n" +
			"adding a redaction pattern to scrub matching values already on disk.",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			syncDirVal := cfg.SyncDir
			if syncArg != "" {
				syncDirVal = syncArg
			}
			host := event.HostName()
			res, err := redactShard(filepath.Join(syncDirVal, "events-"+host+".jsonl"), cfg.StoreDir, host, dryRun)
			if err != nil {
				return err
			}
			verb := "redacted"
			if dryRun {
				verb = "[dry-run] would redact"
			}
			fmt.Printf("%s: %s %d of %d events (%d malformed lines preserved)\n",
				res.shard, verb, res.changed, res.events, res.malformed)
			return nil
		},
	}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "report how many events would change without writing")
	cmd.Flags().StringVar(&syncArg, "sync-dir", "", "override sync directory (default from config)")
	return cmd
}

type redactShardResult struct {
	shard     string
	events    int
	changed   int
	malformed int
}

// redactShard re-runs redaction over each event line. It rewrites the shard
// only when something changed, using the same atomic temp+rename+fsync +
// per-host lock the compactor uses.
func redactShard(shardPath, storeDir, host string, dryRun bool) (*redactShardResult, error) {
	res := &redactShardResult{shard: filepath.Base(shardPath)}
	if !dryRun && storeDir != "" {
		lock, err := event.AcquireHostLock(storeDir, host)
		if err != nil {
			return nil, fmt.Errorf("host lock: %w", err)
		}
		defer func() { _ = lock.Release() }()
	}
	data, err := os.ReadFile(shardPath)
	if err != nil {
		if os.IsNotExist(err) {
			return res, nil
		}
		return nil, err
	}
	var out bytes.Buffer
	out.Grow(len(data))
	changed := false
	rest := data
	for len(rest) > 0 {
		nl := bytes.IndexByte(rest, '\n')
		var line []byte
		var hadNL bool
		if nl < 0 {
			line = rest
			rest = nil
		} else {
			line = rest[:nl]
			rest = rest[nl+1:]
			hadNL = true
		}
		red, lineChanged, isEvent := redactEventLine(line)
		if isEvent {
			res.events++
			if lineChanged {
				res.changed++
				changed = true
			}
			out.Write(red)
		} else {
			if len(bytes.TrimSpace(line)) > 0 {
				res.malformed++
			}
			out.Write(line)
		}
		if hadNL {
			out.WriteByte('\n')
		}
	}
	if dryRun || !changed {
		return res, nil
	}
	if err := rewriteShard(shardPath, out.Bytes()); err != nil {
		return nil, fmt.Errorf("rewrite shard: %w", err)
	}
	return res, nil
}

// redactEventLine re-redacts one JSON event line. Returns:
//   - (redacted, true, true)  when redaction changed the event,
//   - (originalLine, false, true) for an unchanged event (exact bytes kept —
//     no cosmetic key reorder), and
//   - (originalLine, false, false) for a blank/malformed line (preserved).
//
// Change detection compares two marshals of the SAME parsed object (before vs
// after redaction) so map key-order differences never masquerade as a change.
func redactEventLine(line []byte) (out []byte, changed, isEvent bool) {
	trimmed := bytes.TrimSpace(line)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return line, false, false
	}
	var obj map[string]any
	if err := json.Unmarshal(trimmed, &obj); err != nil {
		return line, false, false
	}
	before, err := json.Marshal(obj)
	if err != nil {
		return line, false, true
	}
	cleaned, _ := redact.ApplyJSON(obj)
	after, err := json.Marshal(cleaned)
	if err != nil {
		return line, false, true
	}
	if bytes.Equal(before, after) {
		return line, false, true // no redaction change → keep original bytes
	}
	return after, true, true
}
