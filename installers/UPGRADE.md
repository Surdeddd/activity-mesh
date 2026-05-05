# Upgrading activity-mesh

The bootstrap script is the upgrade script.

```bash
# any host, any OS
bash installers/bootstrap.sh
# or:
pwsh installers/bootstrap.ps1
```

It re-downloads both binaries (`activity-log` + `activity-watcher`), re-renders supervisor units, restarts services. It does **not** touch:
- `~/.local/share/activity-mesh/index.db` (rebuildable from JSONL)
- `~/Sync/activity/events-*.jsonl` (cross-host source of truth)
- `~/.config/activity-mesh/` (any local config)

So the upgrade is safe by construction — destroying the index forces a rebuild on next start, but no event data is lost.

## Pinning a version

```bash
bash installers/bootstrap.sh --version v1.2.0
```

This downloads the exact `activity-log-<os>-<arch>` and `activity-watcher-<os>-<arch>` assets attached to release `v1.2.0`. The two binaries are versioned together (single repo, single release).

## Semver compatibility

activity-mesh uses semantic versioning starting at v1.0.0:

| bump | meaning | upgrade safety |
|---|---|---|
| **patch** (v1.2.0 → v1.2.1) | bugfix only, no schema change | safe to upgrade in place, restart picks up |
| **minor** (v1.2.0 → v1.3.0) | new event kinds, additive fields, new flags | safe; readers tolerate unknown fields |
| **major** (v1.x → v2.0) | breaking schema or CLI change | requires coordinated multi-host upgrade |

The event schema has its own version field (`v` in every JSONL line). Major schema bumps run a migration chain on read — old events on disk are never rewritten, only adapted in-memory. See `ARCHITECTURE.md → "Schema versioning + migration"`.

## Rolling upgrade across hosts

Because data lives on Syncthing-replicated JSONL and each host has its own per-host shard, you can upgrade one machine at a time:

1. Upgrade macbook → bootstrap.sh
2. Verify with `activity-log status` and `query --hours 1`
3. Upgrade mac-mini → bootstrap.sh
4. Repeat for any other host

For **major** bumps that change the wire schema, do all hosts in one session — old writers + new readers in the same `~/Sync/activity/` may produce events the older clients cannot parse. The reader migration chain still tolerates this, but emitting `v=2` events while another host runs `v=1` only is unsupported.

## Rolling back

Re-run with the previous tag:

```bash
bash installers/bootstrap.sh --version v1.2.0
```

The binary is replaced atomically. The supervisor unit re-renders with the same path, so launchd/systemd/schtasks pick up the new (older) binary on next start.

## Rebuilding the index

If the FTS5 index gets corrupt:

```bash
activity-log reindex
# or, nuclear:
rm -rf ~/.local/share/activity-mesh/index.db
launchctl kickstart -k gui/$(id -u)/com.activity-mesh.daemon   # mac
systemctl --user restart activity-mesh-daemon                   # linux
schtasks /End /TN \activity-mesh\daemon && schtasks /Run /TN \activity-mesh\daemon  # win
```

Indexer rebuilds from `~/Sync/activity/events-*.jsonl` on startup.

## Uninstall before re-install (rare)

Only if bootstrap upgrade misbehaves:

```bash
bash installers/uninstall.sh           # keeps data
bash installers/bootstrap.sh           # fresh install, re-uses preserved data
```

`--purge` is destructive — only use to wipe everything.
