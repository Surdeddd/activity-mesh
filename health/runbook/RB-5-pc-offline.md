# RB-5 — PC machine offline >48h

## Symptoms
- `silence` for `events-pc.jsonl` exceeds 48h (default threshold 24h)
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
3. **PC online but writer dead** — windows: re-register Task Scheduler entry from `installers/templates/taskscheduler-watcher.xml.tmpl`; linux: `systemctl --user restart activity-mesh-watcher.service`.

## Verification
- New events appear in `events-pc.jsonl` within 5 minutes of recovery.
- `silence` check returns tier 1.
- Weekly digest next Sunday lists pc in per-host counts.
