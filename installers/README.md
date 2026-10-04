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
bash installers/uninstall.sh --purge    # also removes the store, state and config dirs; never touches the sync dir
bash installers/uninstall.sh --dry-run  # print the plan, change nothing
```

- **Binaries** are removed from `--prefix` (default `/usr/local/bin`) and from
  `~/.local/bin`, where earlier installs put them.
- **Store and state dirs** follow `ACTIVITY_MESH_HOME` and `ACTIVITY_MESH_STATE`
  exactly like bootstrap (defaults `~/.local/share/activity-mesh` and
  `~/.local/state/activity-mesh`). Each value must be an absolute path without a
  newline. It is resolved to the name the filesystem stores (symlinks, `.` and
  `..`, trailing slashes and, on macOS, the case spelling and the `/private`
  alias; a `.` or `..` below something that does not exist cannot be resolved
  and is refused). Everything is checked before anything is planned or removed,
  and nothing is removed unless the resolved directory positively looks like
  activity-mesh's own:
  - it is not `/`, a mount point (its device differs from its parent's) or, on
    macOS, `/System`, `/System/Volumes` or a volume root such as
    `/System/Volumes/Data`;
  - its subdirectories are only the ones activity-mesh makes: `audit` and `dist`
    in the store, none in the state and config dirs (files are not examined);
  - it holds at least one file activity-mesh writes: `config.json`,
    `cursors.json`, `index.db`, `seq-*` or `dist/current` in the store; `*.log`,
    `*.err`, `last-health.json`, `last-digest.json`, `decay-state.json`,
    `heartbeat-misses`, `heartbeat-last-alert`, `clock-offset-ms` or `tokens-*`
    in the state dir; `watcher.yaml`, `scopes-cache`, `agents-cache` or
    `telegram.env` in the config dir. A directory with no entries at all
    (hidden ones included), such as the state dir of an install made with
    `--no-services`, needs no marker, passes the checks above like any other
    and is removed with `rmdir`, never `rm -rf`: if something has appeared in it
    since the check, `rmdir` fails, the uninstall says so and stops, and nothing
    is deleted.

  Without `--purge` only `<store>/dist` is held to this: it may hold only
  version dirs (`0.4.0`, `v0.4.0-rc.7`, `dev-local`) and `current`. A directory
  that fails is refused with up to five of the entries that are in the way, and
  nothing is changed.

  Besides that, as a second line of defence, a value is refused when it is `/`,
  your home directory or one of its parents, a sync dir, one of its parents or
  anything inside it, or a directory that holds the default `activity-mesh`
  store, state or config dirs (`~/.local/share`, `~/.config`, ...). Those are
  compared by resolved name
  and by device and inode (on macOS also through the `/System/Volumes/Data`
  spelling of each protected path and its parents), and the uninstall stops when
  it cannot read an identity (no `stat`, a HOME that does not exist, a name that
  resolves to another directory than the one it names, no `/bin/pwd` on macOS).

  What is removed is the resolved path. A symlink you named it by is removed as
  well, and so is every link of a chain (`link1 -> link2 -> dir`) that led to
  it, so a purge leaves no dangling link behind; a link that only leads to the
  parent of the dir stays. Registrations are matched under both the spelling you
  gave and the resolved one.
- **The sync dir** is never removed, and every candidate is protected:
  `ACTIVITY_MESH_SYNC`, the `sync_dir` in `<store>/config.json` (of the store
  you name and of the default store, read the way bootstrap reads it) and
  `~/Sync/activity`. For a symlinked sync dir the parents of the link and the
  parents of its target are both protected. The line "left ... alone" names the
  one bootstrap would use. A `sync_dir` that cannot be decoded stops the
  uninstall unless `ACTIVITY_MESH_SYNC` says where the sync dir is.
- **Hooks and MCP registrations** that point into `<store>/dist/` would be dead
  once `dist/` is gone, so they are removed first: the Claude Code hooks in
  `~/.claude/settings.json` (`CLAUDE_SETTINGS` overrides the path), the
  `activity-mesh` MCP server (`claude mcp remove activity-mesh --scope user`,
  or `jq` on `~/.claude.json` without the `claude` CLI) and the
  `[mcp_servers.activity-mesh]` table of `~/.codex/config.toml` (with its
  sub-tables and arrays of tables, wherever they sit in the file; the comments
  around it stay). Each edited file gets a
  `.bak-<timestamp>` copy, symlinked files are edited in their target with
  their permissions kept, and entries that point at a repo checkout are left
  alone. A Hermes entry is only reported, and so is anything in `config.toml`
  that still points into `dist/` after the edit (an inline-table
  `activity-mesh = { ... }`, another server). The JSON files need `jq`; without
  it you get the command to run by hand.

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
A script started through a symlink is followed to the real file first, so it
finds the helper and registers the hooks and server that sit next to it; a
`dist/current` link in the directory path is kept as written.
It holds the write-through-symlinks, mode-preserving writer, the one scanner
for the `[mcp_servers.activity-mesh]` table of a Codex `config.toml`, so
install and uninstall agree on what that table is and on keeping the comments
around it, and the path helpers the uninstall guard is built on (resolving a
path to the name the filesystem stores, device and inode identity, reading
`sync_dir` from `config.json`). It ships in the release archive and under
`dist/<version>/installers/lib/`; `bootstrap.sh` refuses an archive whose
scripts need it but lack it. A script started without it prints the missing
path and changes nothing.

## Testing

`make test-install` runs a hermetic end-to-end install: builds the binaries,
assembles a fake release archive, serves it over local HTTP, and bootstraps
into a temp `HOME` with `--no-services`, then asserts binaries, assets, units,
registries, a queryable smoke event, and hard failure on checksum mismatch.
The same target runs `tests/install/test-cfgedit.sh` (the shared helper on its
own: symlink-chain writes, every shape of Codex table), `tests/install/test-integration.sh`
(the integration/hooks/MCP installers: symlinked config files, preserved
permissions, in-place Codex update) and `tests/install/test-uninstall.sh`
(env-relocated and unsafe dirs, hook and MCP removal, alternate prefix), each
with a temp `HOME` and log-only `PATH` shims for `claude`, `launchctl`,
`systemctl` and `sudo`; anything that feeds the uninstall an unsafe path runs
with `--dry-run`.
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
