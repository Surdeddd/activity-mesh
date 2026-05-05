# RB-6 — launchd plist won't load (or stuck)

## Symptoms
- `launchd-jobs` tier ≥ 2 (missing labels)
- `dead-man-heartbeat` fires repeatedly (daemon unreachable)
- `launchctl list | grep com.activity-mesh` returns nothing or "?" PID

## Diagnosis
```sh
launchctl list | grep com.activity-mesh
launchctl print gui/$(id -u)/com.activity-mesh.daemon | head -40
ls -la ~/Library/LaunchAgents/com.activity-mesh.*.plist
plutil -lint ~/Library/LaunchAgents/com.activity-mesh.daemon.plist
tail -50 ~/.local/state/activity-mesh/daemon.err
```

Common: ThrottleInterval rate-limit after rapid crashes; plist bad XML; binary path unset; SIP blocking.

## Recovery
1. `launchctl bootout gui/$(id -u)/com.activity-mesh.daemon` (full unload).
2. Fix plist: rerun installer `installers/macos/install.sh` to render template again.
3. `plutil -lint` must report OK.
4. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.activity-mesh.daemon.plist`.
5. `launchctl kickstart -k gui/$(id -u)/com.activity-mesh.daemon`.
6. Confirm with `curl -s http://127.0.0.1:7459/health`.

## Verification
- `launchd-jobs` tier 1.
- `dead-man-heartbeat` log shows `ok url=...` and `prev_misses=0`.
