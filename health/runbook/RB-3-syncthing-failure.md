# RB-3 — Syncthing wholesale failure

## Symptoms
- `sync-lag` tier 3 across all peers
- `conflict` shows multiple `.sync-conflict-*` files
- Syncthing UI (`http://127.0.0.1:8384`) shows folder error / db locked

## Diagnosis
```sh
launchctl list | grep syncthing
curl -s http://127.0.0.1:8384/rest/system/status -H "X-API-Key:$ST_API_KEY"
ls -la ~/Library/Application\ Support/Syncthing/
df -h $HOME                                # disk full?
```

## Recovery
1. Restart Syncthing: `launchctl kickstart -k gui/$(id -u)/<your-syncthing-label>` on macOS, `systemctl --user restart syncthing` on Linux, or the tray app.
2. If db locked: stop Syncthing, `mv ~/Library/Application\ Support/Syncthing/index-v0.14.0.db{,.bak-$(date +%s)}`, restart — Syncthing rebuilds.
3. For each `.sync-conflict-*` file, decide manually: usually keep the newer mtime, delete the older. JSONL is append-only so concatenate is also valid.
4. Verify all peers show "Up to Date" in Syncthing UI.

## Verification
- `health/master.sh` → `conflict` ok, `sync-lag` ok.
- New event written on host A appears on host B's shard within 30s.
