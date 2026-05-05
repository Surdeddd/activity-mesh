# RB-2 — secret leaked into log (urgent)

## Symptoms
- `secrets-bypass` or `redactor-coverage` check tier 3+
- Visual confirmation in shard or audit log

## Diagnosis
```sh
grep -nE 'sk-ant-|sk-[A-Za-z0-9]{40}|ghp_|xox[abp]-|AKIA|-----BEGIN' \
  ~/Sync/activity/events-*.jsonl
# Note: line numbers + shard
```

## Recovery
1. **Revoke first, fix log second.** Open the leaked credential's issuer dashboard (Anthropic, GitHub, AWS, Slack...) and rotate immediately.
2. Stop writers (`launchctl unload com.activity-mesh.*`).
3. Sed-redact the leaked value in place across all shards on **all hosts** (Syncthing will propagate):
   ```sh
   activity-log redact --in-place --pattern '<exact-leaked-string>'
   ```
4. Truncate WAL/SHM, rebuild index: `activity-log reindex --rebuild`.
5. Add the matched pattern to `~/Sync/activity/redaction.yaml` so tier-1 catches it next time.
6. Append entry to `~/.local/share/activity-mesh/audit/redactions-YYYY-MM.jsonl.age`.

## Verification
- `secrets-bypass` returns tier 1 ok.
- Issuer dashboard shows credential revoked + new one provisioned.
- Audit log encrypted with `age -d` reveals one redaction line for the rotated cred.
