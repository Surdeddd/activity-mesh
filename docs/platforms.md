# Platform support

macOS and Linux are first-class: capture, injection, daemon, and monitoring all
run there. Windows ships the CLI only.

| capability | macOS | Linux | Windows |
|---|---|---|---|
| CLI (emit/query/compact/redact-shard/clock-sync) | ✅ | ✅ | ✅ (`activity-log.exe`) |
| fsnotify capture watcher | ✅ | ✅ | ❌ |
| HTTP query daemon (`:7459`) | ✅ | ✅ | ❌ |
| Claude Code hooks (L2/L3) | ✅ | ✅ | ❌ |
| health checks / heartbeat / weekly digest | ✅ | ✅ (cron/timers) | ❌ |
| supervisor units via bootstrap | 6 launchd units | 2 systemd units + documented cron | none (CLI-only) |

Windows is deliberately **CLI-only**: the release zip ships `activity-log.exe`
and the registries; there is no watcher, daemon, or scheduled task support. A
Windows host can still emit and query events against a synced shard directory —
it just won't capture or inject automatically.
