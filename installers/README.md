# activity-mesh — Installers

Cross-platform install scripts. Run one command, system is up.

## Quick start

### macOS (Apple Silicon or Intel)

```bash
curl -fsSL https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.sh | bash

# or, if cloned:
bash installers/bootstrap.sh
```

This will:
1. Detect arch (`darwin-arm64` or `darwin-amd64`)
2. Download two binaries from the latest GitHub release:
   - `activity-log-darwin-<arch>` → `/usr/local/bin/activity-log`
   - `activity-watcher-darwin-<arch>` → `/usr/local/bin/activity-watcher`
   (will prompt for sudo if `$PREFIX` not writable)
3. Scaffold dirs: `~/.local/share/activity-mesh/`, `~/Sync/activity/`, `~/.config/activity-mesh/`
4. Copy default `configs/watcher.yaml` → `~/.config/activity-mesh/watcher.yaml` (only if not already present)
5. Render + bootstrap two `launchd` agents:
   - `~/Library/LaunchAgents/com.activity-mesh.watcher.plist` (runs `activity-watcher --config ...`)
   - `~/Library/LaunchAgents/com.activity-mesh.daemon.plist` (runs `activity-log daemon` — requires P3)
6. Run `activity-log status` and a smoke `emit` to verify.

### Linux (amd64 or arm64)

```bash
curl -fsSL https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.sh | bash
```

Same flow, but generates `systemd` user units:
- `~/.config/systemd/user/activity-mesh-watcher.service`
- `~/.config/systemd/user/activity-mesh-daemon.service`

The script also calls `loginctl enable-linger $USER` so services keep running after logout. If you don't want that, add `--no-linger` (TODO future flag) or remove with `loginctl disable-linger`.

### Windows (PowerShell 7+)

```powershell
iwr https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.ps1 -OutFile bootstrap.ps1
pwsh ./bootstrap.ps1
```

This will:
1. Download both binaries to `%USERPROFILE%\bin\`:
   - `activity-log-windows-amd64.exe` → `activity-log.exe`
   - `activity-watcher-windows-amd64.exe` → `activity-watcher.exe`
2. Add the bin dir to user PATH
3. State dir: `%LOCALAPPDATA%\activity-mesh\` (per Windows convention)
4. Copy default `configs\watcher.yaml` → `%APPDATA%\activity-mesh\watcher.yaml`
5. Register two Task Scheduler tasks (XML-based) under `\activity-mesh\`:
   - `\activity-mesh\watcher`
   - `\activity-mesh\daemon`
6. Run smoke verification

## Flags

### bootstrap.sh

| flag | default | meaning |
|---|---|---|
| `--dry-run` | off | print every action, do nothing destructive |
| `--version vX.Y.Z` | `latest` | pin a specific release tag |
| `--prefix DIR` | `/usr/local/bin` | install dir for binary |

### bootstrap.ps1

| flag | default | meaning |
|---|---|---|
| `-DryRun` | off | print every action, do nothing destructive |
| `-Version vX.Y.Z` | `latest` | pin a specific release tag |
| `-Prefix DIR` | `$env:USERPROFILE\bin` | install dir |

### uninstall.sh / uninstall.ps1

| flag | default | meaning |
|---|---|---|
| `--purge` (sh) / `-Purge` (ps1) | off | also delete state/config; leaves `~/Sync/activity` alone |
| `--keep-data` (sh) | on | keep state/config (default) |
| `--dry-run` / `-DryRun` | off | print plan only |

## Idempotency

All scripts are safe to re-run. The bootstrap path:
- skips `mkdir` if dir exists,
- overwrites supervisor unit files (template re-render),
- bootstraps services after `bootout` to pick up the new unit cleanly,
- never resets config or state.

That makes the same command both *install* and *upgrade*. See `UPGRADE.md`.

## Verification

After running bootstrap, you should see:

```
[OK] mkdir ~/.local/share/activity-mesh
[OK] binary installed → /usr/local/bin/activity-log
[OK] rendered ~/Library/LaunchAgents/com.activity-mesh.watcher.plist
[OK] launchd bootstrapped com.activity-mesh.watcher
[OK] rendered ~/Library/LaunchAgents/com.activity-mesh.daemon.plist
[OK] launchd bootstrapped com.activity-mesh.daemon
[OK] verification done
[OK] bootstrap complete on macbook (darwin/arm64)
```

To poke it manually:

```bash
activity-log status
activity-log emit --kind status --scope bootstrap --summary "manual test"
activity-log query --hours 24 | head
launchctl list | grep activity-mesh   # mac
systemctl --user status activity-mesh-daemon   # linux
schtasks /Query /TN \activity-mesh\daemon      # windows
```

## Templates

Supervisor unit templates live in `installers/templates/`. They use `{{PLACEHOLDER}}` syntax — the bootstrap scripts do textual substitution. Edit a template if you need a non-default port, working dir, or environment.

Placeholders:
- `{{BIN_PATH}}` — full path to `activity-log` binary (used by daemon unit)
- `{{WATCHER_BIN}}` — full path to `activity-watcher` binary (used by watcher unit)
- `{{STATE_DIR}}` — per-host state (`~/.local/share/activity-mesh` or `%LOCALAPPDATA%\activity-mesh`).
  Exception: the manually-rendered heartbeat template uses it for `ACTIVITY_MESH_STATE`,
  which must be the *runtime* state dir `~/.local/state/activity-mesh` (see comment in
  `launchd-heartbeat.plist.tmpl`)
- `{{CONFIG_DIR}}` — config dir holding `watcher.yaml`
- `{{SYNC_DIR}}` — Syncthing-replicated source-of-truth
- `{{LOG_DIR}}` — daemon stdout/stderr path
- `{{HOME}}` — user home
- `{{USER}}` — login name (Windows: `DOMAIN\user`)

## When releases don't exist yet

The repo just got created — there are no GitHub releases yet. The scripts fall back to a warning and skip the binary install when the release URL 404s. The dirs and supervisor units are still created, so you can build both binaries locally:

```bash
go build -o /usr/local/bin/activity-log     ./cmd/activity-log
go build -o /usr/local/bin/activity-watcher ./cmd/activity-watcher
# then re-run bootstrap to verify the rest
```

The `daemon` supervisor unit runs `activity-log daemon` which is part of P3 (still pending in `ROADMAP.md`). Until P3 ships, the daemon unit will fail to start and launchd/systemd will throttle restarts every 30s. This is harmless — the watcher unit and the CLI work independently.

## Troubleshooting

### macOS
- `launchctl bootstrap` fails → already loaded; the script `bootout`s first, but if your shell is in a weird state, `launchctl kickstart -k gui/$(id -u)/com.activity-mesh.daemon` forces restart.
- `Operation not permitted` → grant Terminal/iTerm/Claude full-disk-access in System Settings → Privacy & Security.

### Linux
- `Failed to enable unit` → ensure `~/.config/systemd/user/` exists and `XDG_RUNTIME_DIR` is set. Re-login.
- `loginctl enable-linger` denied → run as user; if still denied, your distro disabled lingering. Services will pause when logged out.

### Windows
- `Access denied` running schtasks → run PowerShell as user, not Administrator. Per-user tasks shouldn't need elevation.
- `Cannot run on this system` policy → `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` then re-run.

## License

MIT. See `../LICENSE`.
