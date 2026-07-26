# RB-9 — mempalace + activity-mesh drift

## Symptoms
- `mempalace search` returns events that no longer exist in `~/Sync/activity/`
- activity-mesh has events that mempalace never embedded
- L3 ambient context disagrees with explicit MCP call output

## Diagnosis
```sh
# count side
wc -l ~/Sync/activity/events-*.jsonl
mempalace status   # drawer counts in 'activity' wing
# spot-check ULIDs
mempalace search "<ulid>" --wing activity --limit 1
```

Likely roots: indexer crashed mid-run, mempalace embed worker offline, archive compaction without sync hook to mempalace, retroactive redaction not propagated.

## Recovery
1. Pause both writers.
2. Compute drift (the event ULID is the `id` field):
   ```sh
   activity-log query --since 30d --limit 0 --format json | jq -r .id | sort > /tmp/am.txt
   mempalace export --wing activity --since 30d | sort > /tmp/mp.txt
   comm -23 /tmp/am.txt /tmp/mp.txt
   ```
3. Re-embed missing events: `mempalace mine --source activity --since 30d --resume`.
4. For redacted entries: `mempalace mine --source activity --redaction-replay`.
5. Resume writers.

## Verification
- `comm -3` of ULID sets is empty modulo last 60s.
- `mempalace search` returns parity of expected items vs `activity-log query`.
- L3 ambient and L4 MCP agree on a sample of 5 prompts.
