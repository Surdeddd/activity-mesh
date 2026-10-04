# RB-4 — hook auto-disabled, fallback growing

## Symptoms
- `hook-health` at tier 2 (1–5 error lines) or tier 3 (more than 5). It reads
  only the three hook logs in `~/.local/state/activity-mesh/` —
  `session-start.log`, `user-prompt-router.log` and `redactor.log` — and counts
  the lines stamped within the last `ACTIVITY_MESH_HEALTH_WINDOW_S` (default
  21600 s = 6 h, the health cadence) that mention error, fail, no binary, not
  found or no jq
- `~/.local/state/activity-mesh/redactor.log` shows fail-closed refusals
- session-start-digest log shows repeated "binary missing" or "exec format error"

## Diagnosis
```sh
ls -la ~/.local/state/activity-mesh/
tail -100 ~/.local/state/activity-mesh/session-start.log
tail -100 ~/.local/state/activity-mesh/user-prompt-router.log
tail -100 ~/.local/state/activity-mesh/redactor.log
file $(command -v activity-log)            # binary intact?
jq '.hooks' ~/.claude/settings.json        # hook entries still present?
```

## Recovery
1. Rebuild + reinstall binary if architecture mismatch: `make build install`.
2. Re-run hook installer: `bash hooks/install.sh`. It is idempotent.
3. Confirm the hooks can find the binary — they resolve `$ACTIVITY_MESH_BIN`,
   then `PATH`, then `~/.local/bin/activity-log`:
   ```sh
   ACTIVITY_MESH_BIN=$(command -v activity-log) activity-log status
   ```
4. Tail logs, send a benign `claude` prompt, confirm hook fires.

## Verification
- `hook-health` returns tier 1.
- `user-prompt-router.log` shows a fresh `emitted intent=…` or `no events` line
  (either proves the hook ran; silence means it did not).
- Fresh prompt produces an event in `events-<host>.jsonl`.
