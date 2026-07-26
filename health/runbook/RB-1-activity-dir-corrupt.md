# RB-1 — activity dir corrupt

## Symptoms
- silence / canary / sync-lag checks all firing tier ≥ 3
- `~/Sync/activity/events-<host>.jsonl` truncated, empty, or contains binary garbage
- ingester log shows JSON parse errors

## Diagnosis
```sh
ls -la ~/Sync/activity/                     # any 0-byte shards?
file ~/Sync/activity/events-*.jsonl         # ASCII text? UTF-8?
tail -1 ~/Sync/activity/events-*.jsonl | jq # last line parses?
sqlite3 ~/.local/share/activity-mesh/index.db 'PRAGMA integrity_check;'
```

## Recovery
1. Stop writers — `launchctl unload ~/Library/LaunchAgents/com.activity-mesh.*.plist`.
2. Backup current state — `tar -cJf /tmp/activity-rescue.tar.xz ~/Sync/activity ~/.local/share/activity-mesh`.
3. Rebuild index from JSONL — the daemon owns the index, so delete it and let it
   replay every shard from offset 0:
   ```sh
   rm -f ~/.local/share/activity-mesh/index.db{,-wal,-shm} \
         ~/.local/share/activity-mesh/cursors.json
   launchctl kickstart -k "gui/$(id -u)/com.activity-mesh.daemon"   # macOS
   systemctl --user restart activity-mesh-daemon                    # Linux
   ```
4. If host shard unrecoverable: pull a peer's copy via Syncthing (set this host receive-only temporarily, accept upstream).
5. Re-load writers. Confirm fresh canary writes appear within 60s.

## Verification
- `health/master.sh --pretty` → silence/canary/index-integrity all `ok`.
- `wc -l ~/Sync/activity/events-<host>.jsonl` increases over 5 minutes.
