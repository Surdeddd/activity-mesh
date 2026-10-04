# Upgrading activity-mesh

The bootstrap script is the upgrade script.

```bash
# macOS / Linux
bash installers/bootstrap.sh
```

```powershell
# Windows (CLI only)
pwsh installers/bootstrap.ps1
```

It re-downloads the release archive (all three binaries on macOS/Linux;
`activity-log.exe` on Windows), verifies the sha256, refuses an archive that
lacks the runtime layout before anything is changed, installs a fresh
versioned assets dir (`~/.local/share/activity-mesh/dist/<version>/`),
re-points `dist/current`, then replaces the binaries, re-renders supervisor
units, and restarts services.
It does **not** touch:

- `~/.local/share/activity-mesh/index.db` (rebuildable from JSONL)
- `~/Sync/activity/events-*.jsonl` (cross-host source of truth)
- `~/.config/activity-mesh/` (local config)
- `~/.local/state/activity-mesh/` (logs, telemetry, heartbeat state)

The upgrade is safe by construction — deleting the index only forces a
rebuild; no event data is ever lost.

## Pinning a version

```bash
bash installers/bootstrap.sh --version v0.4.0
```

Downloads the exact `activity-mesh_<ver>_<os>_<arch>` archive attached to
that release. All binaries and runtime assets are versioned together.
Without `--version`, bootstrap installs the newest release, prereleases
included.

## Semver compatibility

| bump | meaning | upgrade safety |
|---|---|---|
| **patch** | bugfix only, no schema change | safe in place |
| **minor** | new event kinds, additive fields, new flags | safe; readers tolerate unknown fields |
| **major** | breaking schema or CLI change | coordinated multi-host upgrade |

The event schema has its own version field (`v` in every JSONL line). Major
schema bumps run a migration chain on read — old events on disk are never
rewritten, only adapted in-memory. See `ARCHITECTURE.md → "Schema versioning
+ migration"`.

## Rolling upgrade across hosts

Data lives on Syncthing-replicated JSONL with one shard per host, so upgrade
one machine at a time:

1. Upgrade host A → `bootstrap.sh`
2. Verify: `activity-log status` and `activity-log query --since 1h`
3. Upgrade the next host

For **major** bumps, do all hosts in one session — emitting `v=2` events
while another host still runs a `v=1`-only build is unsupported.

## Rolling back

```bash
bash installers/bootstrap.sh --version v0.4.0-rc.7
```

Roll back only to a release that ships the full runtime layout (v0.4.0-rc.1
or later). An older archive is refused before the installed binaries or
`dist/current` are touched. `dist/current` re-points to the older assets,
the binaries are replaced, and units re-render and restart.

## Rebuilding the index

```bash
rm -f ~/.local/share/activity-mesh/index.db ~/.local/share/activity-mesh/cursors.json
launchctl kickstart -k gui/$(id -u)/com.activity-mesh.daemon   # macOS
systemctl --user restart activity-mesh-daemon                  # Linux
```

The daemon rebuilds from `~/Sync/activity/events-*.jsonl` on startup. (The
index also self-heals: any shard rewrite is detected via a prefix hash and
reconciled automatically.)

## Uninstall before re-install (rare)

```bash
bash installers/uninstall.sh           # keeps data
bash installers/bootstrap.sh           # fresh install, re-uses preserved data
```

`--purge` is destructive — only use it to wipe state/config on purpose.
