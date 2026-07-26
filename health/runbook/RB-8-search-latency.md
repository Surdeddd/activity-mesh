# RB-8 — search latency runaway

## Symptoms
- L4 MCP `activity_search` calls timing out
- `index-integrity` warns
- `index.db` size growing unbounded
- daemon p95 latency >500ms in `state.json`

## Diagnosis
```sh
sqlite3 ~/.local/share/activity-mesh/index.db <<EOF
PRAGMA integrity_check;
PRAGMA wal_checkpoint(TRUNCATE);
SELECT count(*) FROM events;
SELECT name FROM sqlite_master WHERE type='index';
EOF
du -sh ~/.local/share/activity-mesh/index.db*
```

## Recovery
1. WAL checkpoint truncate (above) — frees `-wal`/`-shm`.
2. `VACUUM` (offline; daemon must stop): `launchctl stop com.activity-mesh.daemon && sqlite3 .../index.db 'VACUUM;' && launchctl start ...`.
3. If FTS5 is corrupted: `DROP TABLE events_fts;` and restart the daemon — it
   recreates the table and repopulates it from `events` on open.
4. Roll over the whole index (the daemon rebuilds it from the shards):
   ```sh
   launchctl stop "gui/$(id -u)/com.activity-mesh.daemon"
   cd ~/.local/share/activity-mesh
   mv index.db "index.db.old.$(date +%s)"; rm -f index.db-wal index.db-shm cursors.json
   launchctl start "gui/$(id -u)/com.activity-mesh.daemon"
   ```
   Deleting `cursors.json` is what forces a full replay; an empty DB also resets
   stale cursors automatically.
5. Shrink the live shard: `activity-log compact --keep 90d` (writes
   `<sync>/archive/events-<host>-YYYY-MM.jsonl.gz`; archives are never indexed).

## Verification
- Search query "claude session-start" returns < 100ms.
- index.db size dropped.
- `index-integrity` ok.
