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

1. Downloads `activity-mesh_<ver>_<os>_<arch>.tar.gz` + `checksums.txt` from the release
   (without `--version`: the newest release, prereleases included).
2. **Verifies sha256** of the archive. If `cosign` is installed, also verifies the
   keyless signature of `checksums.txt` (`--require-signature` makes that mandatory;
   without cosign the script says plainly that only the checksum was verified).
3. Checks that the archive carries the three binaries and the runtime layout
   (`VERSION`, `health/`, `hooks/`, `configs/`, `registries/`, unit templates) and
   refuses it otherwise — nothing on the machine has changed at that point.
4. **Stages** the three binaries next to their final location, as
   `<prefix>/.activity-log.new`, `<prefix>/.activity-watcher.new` and
   `<prefix>/.activity-mesh-daemon.new` (`--prefix`, default `/usr/local/bin`).
   If the prefix is not writable, this is where `sudo` is asked for — before
   anything else on the machine has changed, so a refused password leaves the
   installed binaries, `dist/current` and the config exactly as they were. A
   failure before the final rename removes the staged files.
5. Scaffolds `~/.local/share/activity-mesh`, `~/.local/state/activity-mesh`,
   `~/Sync/activity`, `~/.config/activity-mesh` (`ACTIVITY_MESH_HOME`,
   `ACTIVITY_MESH_STATE` and `ACTIVITY_MESH_SYNC` relocate the first three).
6. Installs runtime assets (health scripts, unit templates, registries, default
   `watcher.yaml`, hooks, MCP server) to `<store>/dist/<version>/`, checks that
   every required file arrived, and only then points the `dist/current` symlink
   at it. **Supervisor units reference `dist/current`, never a repo checkout.**
7. Renames the staged binaries into place (`mv -f`), so the new assets and the new
   binaries switch together. A warning names an older `activity-log` that wins on
   `PATH`.
8. Seeds the default `watcher.yaml` into `~/.config/activity-mesh` and any missing
   registries into the sync dir; runs `activity-log init --sync-dir ... --yes`
   and `refresh-caches`.
9. macOS: renders + bootstraps **6 launchd units** (`watcher`, `daemon`, `health`,
   `heartbeat`, `compact`, `weekly-digest`).
   Linux: renders + enables 2 systemd user units (`watcher`, `daemon`) and calls
   `loginctl enable-linger`; periodic jobs are documented below.
10. Smoke-verifies: `--version`, `status`, one `emit`, then prints `bootstrap complete`.

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
| `--version vX.Y.Z` | `latest` | pin a release tag (`latest` = newest release, prereleases included) |
| `--prefix DIR` | `/usr/local/bin` | binary install dir (made absolute; staged files and the final binaries both live here) |
| `--no-services` | off | render units but do not register them (tests, containers); on macOS they go to `dist/<version>/units/`, not `~/Library/LaunchAgents` (launchd loads that dir at every login) |
| `--local` | off | use the repo checkout as the asset source and rebuild all three binaries with Go (falls back to the installed binaries only when no toolchain is present) |
| `--require-signature` | off | fail unless the cosign signature of checksums.txt verifies |

Env overrides: `ACTIVITY_MESH_REPO`, `ACTIVITY_MESH_BASE_URL` (custom download
base; requires `--version`), `ACTIVITY_MESH_SYNC`, `ACTIVITY_MESH_HOME`,
`ACTIVITY_MESH_STATE`, `TELEGRAM_ENV`, `PREFIX`, `VERSION`.

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

Re-run the same bootstrap command. The new binaries are staged first (a `sudo`
prompt, if the prefix needs one, happens there, before anything changes), then
a new `dist/<version>/` is installed and `current` re-pointed, then the staged
binaries are renamed into place; units are re-rendered and re-registered.
Config, state, and the sync dir are never reset. Old `dist/<version>`
directories can be deleted by hand once nothing references them.

## Uninstall

```bash
bash installers/uninstall.sh            # units + binaries + dist assets + registrations that point into dist; keeps data
bash installers/uninstall.sh --purge    # also removes the store, state and config dirs; never touches ~/Sync/activity
bash installers/uninstall.sh --dry-run  # print the plan, change nothing
```

- **Binaries** are removed from `--prefix` (default `/usr/local/bin`) and from
  `~/.local/bin`, where earlier installs put them.
- **Store and state dirs** follow `ACTIVITY_MESH_HOME` and `ACTIVITY_MESH_STATE`
  exactly like bootstrap (defaults `~/.local/share/activity-mesh` and
  `~/.local/state/activity-mesh`). Each value must be an absolute path. It is
  normalized first (trailing slashes, `.` and `..`, symlinks resolved) and
  refused, before anything is planned or removed, when it is `/`, your home
  directory or one of its parents (also through a symlink), the sync dir or one
  of its parents, or a directory that holds the default `activity-mesh` store,
  state or config dirs (`~/.local/share`, `~/.config`, ...). What is removed is
  the normalized path, and registrations are matched under both the spelling you
  gave and the resolved one.
- **Hooks and MCP registrations** that point into `<store>/dist/` would be dead
  once `dist/` is gone, so they are removed first: the Claude Code hooks in
  `~/.claude/settings.json` (`CLAUDE_SETTINGS` overrides the path), the
  `activity-mesh` MCP server (`claude mcp remove activity-mesh --scope user`,
  or `jq` on `~/.claude.json` without the `claude` CLI) and the
  `[mcp_servers.activity-mesh]` table of `~/.codex/config.toml`. Each edited
  file gets a `.bak-<timestamp>` copy, symlinked files are edited in their
  target with their permissions kept, and entries that point at a repo checkout
  are left alone. A Hermes entry is only reported. The JSON files need `jq`;
  without it you get the command to run by hand.

```powershell
pwsh ./installers/uninstall.ps1         # removes activity-log.exe; -Purge also removes .local\share\activity-mesh and .local\state\activity-mesh
```

## Templates

Unit templates live in `installers/templates/` (shipped inside the release
archive, installed under `dist/<version>/installers/templates/`). Placeholders
substituted by bootstrap: `{{BIN_PATH}}`, `{{WATCHER_BIN}}`, `{{DAEMON_BIN}}`,
`{{STORE_DIR}}`, `{{STATE_DIR}}`, `{{SYNC_DIR}}`, `{{CONFIG_DIR}}`,
`{{TELEGRAM_ENV}}`, `{{ASSETS_DIR}}` (→ `dist/current`), `{{HOME}}`, `{{USER}}`.
An unresolved placeholder aborts the install.

## Shared helper

The scripts that edit your configuration files (`hooks/install.sh`,
`mcp/install.sh`, `integration/install.sh`,
`integration/update-session-end-flush.sh`, `installers/uninstall.sh`) all source
`installers/lib/cfgedit.sh`, found relative to their own location (`lib/` from
`installers/`, `../installers/lib/` from `hooks/`, `integration/` and `mcp/`).
It holds the write-through-symlinks, mode-preserving writer, so there is one
copy to fix. It ships in the release archive and under
`dist/<version>/installers/lib/`; `bootstrap.sh` refuses an archive whose
scripts need it but lack it. A script started without it prints the missing
path and changes nothing.

## Testing

`make test-install` runs a hermetic end-to-end install: builds the binaries,
assembles a fake release archive, serves it over local HTTP, and bootstraps
into a temp `HOME` with `--no-services`, then asserts binaries, assets, units,
registries, a queryable smoke event, and hard failure on checksum mismatch.
The same target runs `tests/install/test-integration.sh` (the
integration/hooks/MCP installers: symlinked config files, preserved permissions,
in-place Codex update) and `tests/install/test-uninstall.sh` (env-relocated
dirs, hook and MCP removal, alternate prefix), each with a temp `HOME` and
log-only `PATH` shims for `claude`, `launchctl`, `systemctl` and `sudo`.
`make test-archives` (needs goreleaser) asserts real release archive contents
per platform. All of them run in CI.

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
