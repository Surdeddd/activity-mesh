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
3. If FTS5 corrupted: drop and rebuild FTS table only — `DROP TABLE events_fts; INSERT INTO events_fts SELECT ... FROM events;`.
4. Roll over: `mv index.db index.db.old.$(date +%s) && activity-log reindex --rebuild` (rebuilds in seconds from JSONL).
5. Add archive-cutoff: `activity-log archive --older-than 90d --compress zstd`.

## Verification
- Search query "claude session-start" returns < 100ms.
- index.db size dropped.
- `index-integrity` ok.
