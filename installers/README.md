# activity-mesh — Installers

One command installs binaries, runtime assets, and supervisor units from a
verified GitHub release.

## Quick start

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.sh | bash

# or, from a cloned repo (uses the checkout as the asset source, builds with Go if needed):
bash installers/bootstrap.sh --local
```

What it does — and fails hard (non-zero exit, no "bootstrap complete") if any step breaks:

1. Downloads `activity-mesh_<ver>_<os>_<arch>.tar.gz` + `checksums.txt` from the release.
2. **Verifies sha256** of the archive. If `cosign` is installed, also verifies the
   keyless signature of `checksums.txt` (`--require-signature` makes that mandatory;
   without cosign the script says plainly that only the checksum was verified).
3. Installs `activity-log`, `activity-watcher`, `activity-mesh-daemon` to `--prefix`
   (default `/usr/local/bin`, sudo only if not writable).
4. Installs runtime assets (health scripts, unit templates, registries, default
   `watcher.yaml`, hooks, MCP server) to `~/.local/share/activity-mesh/dist/<version>/`
   and points the `dist/current` symlink at it. **Supervisor units reference
   `dist/current`, never a repo checkout.**
5. Scaffolds `~/.local/share/activity-mesh`, `~/.local/state/activity-mesh`,
   `~/Sync/activity`, `~/.config/activity-mesh`; seeds missing registries into the
   sync dir; runs `activity-log init --sync-dir ... --yes` and `refresh-caches`.
6. macOS: renders + bootstraps **6 launchd units** (`watcher`, `daemon`, `health`,
   `heartbeat`, `compact`, `weekly-digest`).
   Linux: renders + enables 2 systemd user units (`watcher`, `daemon`) and calls
   `loginctl enable-linger`; periodic jobs are documented below.
7. Smoke-verifies: `--version`, `status`, one `emit`, then prints `bootstrap complete`.

### Windows (PowerShell 7+) — CLI only

Windows releases ship **only `activity-log.exe`**. There is no watcher, no daemon,
no scheduled tasks on Windows. Emit/query/compact against a Syncthing-replicated
sync dir work; the auto-capture and HTTP layers are macOS/Linux.

```powershell
iwr https://raw.githubusercontent.com/Surdeddd/activity-mesh/main/installers/bootstrap.ps1 -OutFile bootstrap.ps1
pwsh ./bootstrap.ps1            # -DryRun to preview, -Version vX.Y.Z to pin
```

It downloads the zip + `checksums.txt`, verifies sha256, installs
`activity-log.exe` to `%USERPROFILE%\bin`, adds it to the user PATH, runs
`init --sync-dir %USERPROFILE%\Sync\activity --yes`, and seeds registries.
Signature verification is not implemented on Windows — the script says so.

## Flags (bootstrap.sh)

| flag | default | meaning |
|---|---|---|
| `--dry-run` | off | print the plan, do nothing |
| `--version vX.Y.Z` | `latest` | pin a release tag |
| `--prefix DIR` | `/usr/local/bin` | binary install dir |
| `--no-services` | off | render units but do not register them (tests, containers) |
| `--local` | off | use the repo checkout as the asset source; build binaries with Go if missing |
| `--require-signature` | off | fail unless the cosign signature of checksums.txt verifies |

Env overrides: `ACTIVITY_MESH_REPO`, `ACTIVITY_MESH_BASE_URL` (custom download
base; requires `--version`), `ACTIVITY_MESH_SYNC`, `TELEGRAM_ENV`, `PREFIX`, `VERSION`.

## Linux periodic jobs

The service units cover the watcher and the daemon. Health, heartbeat, compact,
and the weekly digest run from `~/.local/share/activity-mesh/dist/current/health/`
— schedule them with cron or systemd timers, e.g.:

```cron
0 */6 * * *  /bin/bash ~/.local/share/activity-mesh/dist/current/health/master.sh
0 * * * *    /bin/bash ~/.local/share/activity-mesh/dist/current/health/dead-man-heartbeat.sh
40 4 1 * *   /usr/local/bin/activity-log compact --keep 90d
0 6 * * 0    /bin/bash ~/.local/share/activity-mesh/dist/current/health/weekly-digest.sh
```

## Upgrades

Re-run the same bootstrap command. Binaries are replaced, a new
`dist/<version>/` is installed and `current` re-pointed, units are re-rendered
and re-registered. Config, state, and the sync dir are never reset. Old
`dist/<version>` directories can be deleted by hand once nothing references them.

## Uninstall

```bash
bash installers/uninstall.sh            # units + binaries + dist assets; keeps data
bash installers/uninstall.sh --purge    # also removes state/config; never touches ~/Sync/activity
```

```powershell
pwsh ./installers/uninstall.ps1         # removes activity-log.exe; -Purge for state
```

## Templates

Unit templates live in `installers/templates/` (shipped inside the release
archive, installed under `dist/<version>/installers/templates/`). Placeholders
substituted by bootstrap: `{{BIN_PATH}}`, `{{WATCHER_BIN}}`, `{{DAEMON_BIN}}`,
`{{STORE_DIR}}`, `{{STATE_DIR}}`, `{{SYNC_DIR}}`, `{{CONFIG_DIR}}`,
`{{TELEGRAM_ENV}}`, `{{ASSETS_DIR}}` (→ `dist/current`), `{{HOME}}`, `{{USER}}`.
An unresolved placeholder aborts the install.

## Testing

`make test-install` runs a hermetic end-to-end install: builds the binaries,
assembles a fake release archive, serves it over local HTTP, and bootstraps
into a temp `HOME` with `--no-services`, then asserts binaries, assets, units,
registries, a queryable smoke event, and hard failure on checksum mismatch.
`make test-archives` (needs goreleaser) asserts real release archive contents
per platform. Both run in CI.

## Troubleshooting

### macOS
- `launchctl bootstrap` fails → `launchctl bootout gui/$(id -u)/com.activity-mesh.<unit>` then re-run bootstrap.
- `Operation not permitted` → grant your terminal Full Disk Access (System Settings → Privacy & Security).

### Linux
- `Failed to enable unit` → ensure `~/.config/systemd/user/` exists and `XDG_RUNTIME_DIR` is set; re-login.
- `loginctl enable-linger` denied → services pause when logged out.

### Windows
- `Cannot run on this system` policy → `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` and re-run.

## License

MIT. See `../LICENSE`.
