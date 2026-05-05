# RB-7 — schema drift unbounded

## Symptoms
- `schema-drift` tier ≥ 2
- New writers (skill / plugin / agent) emit kinds/scopes not in registry
- L3 router can't match scope-named intents because cache stale

## Diagnosis
```sh
# Distinct unknown kinds in last 24h
jq -r 'select(.ts > "...") | .kind' ~/Sync/activity/events-*.jsonl | sort -u
# Compare to whitelist
yq '.kinds[].name' ~/Sync/activity/kinds.yaml
diff <(...) <(...)
```

## Recovery
1. Decide policy per drift item:
   - Legitimate new kind/scope → add to `kinds.yaml` / `scopes.yaml` (open registry, just YAML).
   - Typo → fix the writer (`activity-log emit --kind ...`) and add migration entry.
   - Malicious / wild → reject by adding to a deny-list and patch the writer.
2. Commit registry change to `~/Sync/activity` (Syncthing replicates).
3. Bump `scopes-cache` for L3 router: `activity-log scopes export > ~/.config/activity-mesh/scopes-cache`.

## Verification
- `schema-drift` tier 1.
- `bash hooks/user-prompt-router.sh` test with a prompt mentioning the new scope returns the expected scoped slice.
