# RB-2 — secret leaked into log (urgent)

## Symptoms
- `secrets-bypass` or `redactor-coverage` check tier 3+
- Visual confirmation in shard or audit log

## Diagnosis
```sh
grep -nE 'sk-ant-|sk-[A-Za-z0-9]{40}|ghp_|xox[abcerspu]-|AKIA|glpat-|hf_|-----BEGIN' \
  ~/Sync/activity/events-*.jsonl
# Note: line numbers + shard
```

## Recovery
1. **Revoke first, fix log second.** Open the leaked credential's issuer dashboard
   (Anthropic, GitHub, AWS, Slack...) and rotate immediately.
2. Stop writers on this host:
   ```sh
   # macOS
   for u in daemon watcher heartbeat compact health weekly-digest; do
     launchctl bootout "gui/$(id -u)/com.activity-mesh.$u" 2>/dev/null || true
   done
   # Linux
   systemctl --user stop activity-mesh-daemon activity-mesh-watcher
   ```
3. Scrub the shard. `redact-shard` re-applies the current rules to **this host's**
   shard only (single-writer invariant) — run it on **every** host whose shard
   holds the value; Syncthing propagates each rewrite:
   ```sh
   activity-log redact-shard --dry-run   # confirm the count first
   activity-log redact-shard
   ```
   If the value survives, it is not in the compiled pack. Check with:
   ```sh
   printf '%s' '<leaked-value>' | activity-log redact --stdin
   ```
   Runtime rules are compiled into the binary (`pkg/redact/redact.go`);
   `registries/redaction.yaml` documents them and changes nothing at runtime.
   Add the rule there **and** in `pkg/redact`, ship a build to every host, then
   re-run `redact-shard`.
4. Rebuild the derived index — never the shards, which are the source of truth:
   ```sh
   rm -f ~/.local/share/activity-mesh/index.db \
         ~/.local/share/activity-mesh/index.db-wal \
         ~/.local/share/activity-mesh/index.db-shm \
         ~/.local/share/activity-mesh/cursors.json
   launchctl kickstart -k "gui/$(id -u)/com.activity-mesh.daemon"   # macOS
   systemctl --user restart activity-mesh-daemon                    # Linux
   ```
   The daemon replays every shard from offset 0; an empty DB also resets any
   stale cursors (`reconcileWithCursors`).
5. Append an incident line to
   `~/.local/share/activity-mesh/audit/redactions-YYYY-MM.jsonl` (plain JSONL,
   mode 0600). `redact-shard` writes no audit row of its own. `age` encryption
   of the audit dir is a v2 item — see ROADMAP.

## Verification
- `activity-log redact-shard --dry-run` reports `0 of N` on **every** host.
- `grep -c '<leaked-fragment>' ~/Sync/activity/events-*.jsonl` → 0 on every host.
- `secrets-bypass` returns tier 1 ok.
- Issuer dashboard shows credential revoked + new one provisioned.
