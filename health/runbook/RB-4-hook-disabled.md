# RB-4 — hook auto-disabled, fallback growing

## Symptoms
- `hook-health` tier ≥ 2 with errors > 5/hour
- `~/.local/state/activity-mesh/fallback-queue/` accumulates files (writes that bypassed daemon)
- session-start-digest log shows repeated "binary missing" or "exec format error"

## Diagnosis
```sh
ls -la ~/.local/state/activity-mesh/
tail -100 ~/.local/state/activity-mesh/session-start.log
tail -100 ~/.local/state/activity-mesh/user-prompt-router.log
file $(command -v activity-log)            # binary intact?
jq '.hooks' ~/.claude/settings.json        # hook entries still present?
```

## Recovery
1. Rebuild + reinstall binary if architecture mismatch: `make build install`.
2. Re-run hook installer: `bash hooks/install.sh`. It is idempotent.
3. Drain fallback queue: `activity-log ingest --from ~/.local/state/activity-mesh/fallback-queue/` then `rm -rf` that dir.
4. Tail logs, send a benign `claude` prompt, confirm hook fires.

## Verification
- `hook-health` returns tier 1.
- Fallback queue empty.
- Fresh prompt produces an event in `events-<host>.jsonl`.
