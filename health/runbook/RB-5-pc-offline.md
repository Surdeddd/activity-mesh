# RB-5 — PC machine offline >48h

## Symptoms
- `silence` at tier 3 with `host=pc`: `events-pc.jsonl` has not changed for
  longer than `ACTIVITY_MESH_SILENCE_MAX_S` (default 43200 s = 12 h, one
  threshold for every host). Silence does not judge within
  `ACTIVITY_MESH_WAKE_GRACE_S` (default 1800 s) of this machine's boot or wake
- mac peers show pc as "Disconnected" in Syncthing
- weekly digest reports zero events from `pc`

## Diagnosis
```sh
# from any peer
mtime=$(stat -f %m ~/Sync/activity/events-pc.jsonl 2>/dev/null \
       || stat -c %Y ~/Sync/activity/events-pc.jsonl)
echo $(( $(date +%s) - mtime )) "seconds since last pc write"
# Syncthing UI → Devices → pc → state
```

## Recovery
Three plausible root causes:
1. **PC powered off / asleep** — wake remotely (Wake-on-LAN if configured) or contact user.
2. **PC online but Syncthing dead** — ssh / Anydesk in, restart `syncthing.service` or run as user, verify folder paused/resumed cycle.
3. **Host online but writer dead** — linux: `systemctl --user restart activity-mesh-watcher.service`.
   Windows is CLI-only: there is no watcher unit to restart, so events come from
   explicit `activity-log emit` calls and git hooks only.

If the PC is off on purpose, register it as offline instead of chasing the
alarm. The offline registry is a JSON object keyed by host
(`~/.claude/channels/telegram/state/offline-hosts.json`; `OFFLINE_HOSTS_JSON`
overrides the path, and the owner's setup maintains it with
`ben-engine offline <host>` / `ben-engine online <host>`). A key matches every
shard whose lower-cased host name contains it, so write keys in lower case.
`silence` then lists the host at tier 1 as owner-disabled, and the weekly digest
leaves its canaries out of the failure share. Remove the key when the host is
back.

## Verification
- New events appear in `events-pc.jsonl` within 5 minutes of recovery.
- `silence` check returns tier 1.
- Weekly digest next Sunday lists pc in per-host counts.
