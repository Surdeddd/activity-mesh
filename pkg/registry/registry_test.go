package registry

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// repoRegistries returns the absolute path to the repo's registries/ dir for
// integration-style tests that read the canonical YAML files.
func repoRegistries(t *testing.T) string {
	t.Helper()
	_, here, _, _ := runtime.Caller(0)
	// here = .../pkg/registry/registry_test.go
	// climb to repo root, then into registries/
	root := filepath.Join(filepath.Dir(here), "..", "..")
	abs, err := filepath.Abs(filepath.Join(root, "registries"))
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	return abs
}

// TestLoad_RealFiles ensures the canonical registries in the repo parse
// cleanly under the current loader. If this breaks, either the YAML drifted
// or the schema bumped — both should be caught by CI.
func TestLoad_RealFiles(t *testing.T) {
	r, err := Load(repoRegistries(t))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if r.Kinds.SchemaVersion != supportedSchemaVersion {
		t.Errorf("kinds schema_version=%d, want %d", r.Kinds.SchemaVersion, supportedSchemaVersion)
	}
	if len(r.Kinds.Core) < 10 {
		t.Errorf("expected ≥10 core kinds, got %d", len(r.Kinds.Core))
	}
	if len(r.Scopes.Scopes) < 5 {
		t.Errorf("expected ≥5 scopes, got %d", len(r.Scopes.Scopes))
	}
	if len(r.Agents.Agents) < 5 {
		t.Errorf("expected ≥5 agents, got %d", len(r.Agents.Agents))
	}
	if len(r.Redaction.Patterns) < 10 {
		t.Errorf("expected ≥10 redaction patterns, got %d", len(r.Redaction.Patterns))
	}
}

// TestKindLookup verifies core + extension lookups round-trip.
func TestKindLookup(t *testing.T) {
	r := mustLoad(t)
	for _, k := range []string{"install", "config", "decision", "task", "note", "status", "error", "handoff", "heartbeat", "canary", "project", "compile"} {
		if !r.IsValidKind(k) {
			t.Errorf("expected core kind %q to be valid", k)
		}
	}
	if !r.IsValidKind("ops/incident") {
		t.Errorf("expected extension kind ops/incident to be valid")
	}
	if r.IsValidKind("totally-made-up-kind") {
		t.Errorf("unknown kind should be invalid")
	}
}

// TestScopeLifecycle exercises the active/deprecated/archived gate.
func TestScopeLifecycle(t *testing.T) {
	r := mustLoad(t)

	allowed, warn := r.CanEmitToScope("demo-app")
	if !allowed || warn != "" {
		t.Errorf("demo-app (active): allowed=%v warn=%q", allowed, warn)
	}

	allowed, warn = r.CanEmitToScope("legacy-service")
	if !allowed {
		t.Errorf("legacy-service (deprecated): expected allowed=true")
	}
	if !strings.Contains(warn, "deprecated") {
		t.Errorf("legacy-service warn missing 'deprecated': %q", warn)
	}

	allowed, warn = r.CanEmitToScope("project:client-x")
	if allowed {
		t.Errorf("project:client-x (archived): expected allowed=false")
	}
	if !strings.Contains(warn, "archived") {
		t.Errorf("archived warn missing 'archived': %q", warn)
	}

	// Unknown scope: forward-compatible pass.
	allowed, warn = r.CanEmitToScope("unknown-scope-xyz")
	if !allowed {
		t.Errorf("unknown scope should pass (forward-compat); got allowed=%v warn=%q", allowed, warn)
	}
}

// TestAgentLookup ensures agent lookups + lifecycle work, including the
// archived-with-expected_silence case.
func TestAgentLookup(t *testing.T) {
	r := mustLoad(t)

	assistant, ok := r.GetAgent("assistant")
	if !ok {
		t.Fatalf("assistant not found")
	}
	if assistant.Status != StatusActive {
		t.Errorf("assistant status=%q, want active", assistant.Status)
	}
	if !r.ExpectsHeartbeat("assistant") {
		t.Errorf("assistant should expect heartbeat")
	}

	retired, ok := r.GetAgent("retired-bot")
	if !ok {
		t.Fatalf("retired-bot not found")
	}
	if retired.Status != StatusArchived {
		t.Errorf("retired-bot status=%q, want archived", retired.Status)
	}
	if r.ExpectsHeartbeat("retired-bot") {
		t.Errorf("retired-bot should NOT expect heartbeat (archived + expected_silence)")
	}
}

// TestActiveScopesAndAgents ensures the active-only filters skip archived
// entries and return sorted output.
func TestActiveScopesAndAgents(t *testing.T) {
	r := mustLoad(t)
	for _, s := range r.ActiveScopes() {
		if s.Status != StatusActive {
			t.Errorf("ActiveScopes returned non-active: %s (%s)", s.Name, s.Status)
		}
		if s.Name == "project:client-x" {
			t.Errorf("archived scope leaked into ActiveScopes")
		}
	}
	for _, a := range r.ActiveAgents() {
		if a.Status != StatusActive {
			t.Errorf("ActiveAgents returned non-active: %s (%s)", a.ID, a.Status)
		}
		if a.ID == "retired-bot" {
			t.Errorf("archived agent leaked into ActiveAgents")
		}
	}
}

// TestScopeRouterFlag — `router: false` opts a scope out of RouterScopes;
// absent and explicit-true both mean included. Non-active scopes never
// appear regardless of the flag.
func TestScopeRouterFlag(t *testing.T) {
	yaml := []byte(`schema_version: 1
scopes:
  - name: zeta
    status: active
  - name: alpha
    status: active
    router: true
  - name: agent-overlap
    status: active
    router: false
  - name: gone
    status: archived
  - name: fading
    status: deprecated
    router: true
`)
	r, err := LoadFromBytes(nil, yaml, nil, nil)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	s, ok := r.GetScope("agent-overlap")
	if !ok || s.RouterEnabled() {
		t.Errorf("agent-overlap: ok=%v RouterEnabled=%v, want found + false", ok, s.RouterEnabled())
	}
	if s, _ := r.GetScope("zeta"); !s.RouterEnabled() {
		t.Errorf("absent router flag must default to enabled")
	}
	got := r.RouterScopes()
	want := []string{"alpha", "zeta"} // sorted; active + router-enabled only
	if len(got) != len(want) {
		t.Fatalf("RouterScopes len=%d, want %d (%v)", len(got), len(want), got)
	}
	for i, name := range want {
		if got[i].Name != name {
			t.Errorf("RouterScopes[%d]=%q, want %q", i, got[i].Name, name)
		}
	}
}

// TestRouterScopes_RealFiles pins the shipped registry: every scope name that
// collides with an agent alias (agents.yaml) must be excluded from the router
// cache, while ordinary scopes stay in.
func TestRouterScopes_RealFiles(t *testing.T) {
	r := mustLoad(t)
	inCache := map[string]bool{}
	for _, s := range r.RouterScopes() {
		inCache[s.Name] = true
	}
	for _, overlap := range []string{"assistant", "worker"} {
		if _, ok := r.GetScope(overlap); !ok {
			t.Errorf("expected scope %q in registry", overlap)
			continue
		}
		if inCache[overlap] {
			t.Errorf("scope %q collides with an agent alias and must be router: false", overlap)
		}
	}
	for _, want := range []string{"demo-app", "infra", "web", "api"} {
		if !inCache[want] {
			t.Errorf("expected scope %q in the router cache", want)
		}
	}
}

// TestSchemaVersionMismatch ensures we refuse YAML written for a future
// schema rather than silently misinterpret.
func TestSchemaVersionMismatch(t *testing.T) {
	bad := []byte("schema_version: 99\nscopes: []\n")
	_, err := LoadFromBytes(nil, bad, nil, nil)
	if err == nil {
		t.Fatalf("expected schema_version mismatch to error")
	}
	if !strings.Contains(err.Error(), "schema_version") {
		t.Errorf("error %q should mention schema_version", err)
	}
}

// TestInvalidStatus catches typos in lifecycle status (e.g. "actve").
func TestInvalidStatus(t *testing.T) {
	bad := []byte(`schema_version: 1
scopes:
  - name: foo
    status: actve
`)
	_, err := LoadFromBytes(nil, bad, nil, nil)
	if err == nil {
		t.Fatalf("expected invalid status to error")
	}
}

// TestInvalidSeverity catches typos in kind severity (e.g. "P9").
func TestInvalidSeverity(t *testing.T) {
	bad := []byte(`schema_version: 1
core:
  - name: foo
    description: bad
    severity_default: P9
`)
	_, err := LoadFromBytes(bad, nil, nil, nil)
	if err == nil {
		t.Fatalf("expected invalid severity to error")
	}
}

// TestLifecycleTransition exercises transitions in-memory: a scope flips
// active → deprecated → archived; CanEmitToScope reflects that.
func TestLifecycleTransition(t *testing.T) {
	yaml := []byte(`schema_version: 1
scopes:
  - name: foo
    status: active
`)
	r, err := LoadFromBytes(nil, yaml, nil, nil)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ok, _ := r.CanEmitToScope("foo"); !ok {
		t.Fatalf("foo (active) should be emit-able")
	}

	yaml2 := []byte(`schema_version: 1
scopes:
  - name: foo
    status: deprecated
    replaced_by: bar
  - name: bar
    status: active
`)
	r2, err := LoadFromBytes(nil, yaml2, nil, nil)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	ok, w := r2.CanEmitToScope("foo")
	if !ok || !strings.Contains(w, "deprecated") || !strings.Contains(w, "bar") {
		t.Errorf("deprecated transition: ok=%v warn=%q", ok, w)
	}

	yaml3 := []byte(`schema_version: 1
scopes:
  - name: foo
    status: archived
`)
	r3, err := LoadFromBytes(nil, yaml3, nil, nil)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ok, _ := r3.CanEmitToScope("foo"); ok {
		t.Errorf("archived scope should refuse emits")
	}
}

// TestRedactionPatterns ensures the redaction file declares the expected
// pattern names — the keys are referenced by audit tooling.
func TestRedactionPatterns(t *testing.T) {
	r := mustLoad(t)
	want := map[string]bool{
		"anthropic_key": false,
		"openai_key":    false,
		"github_token":  false,
		"aws_access_key": false,
		"jwt":           false,
		"private_key_pem": false,
		"db_url":        false,
		"email":         false,
		"user_path":     false,
		"lan_ip":        false,
	}
	for _, p := range r.Redaction.Patterns {
		if _, ok := want[p.Name]; ok {
			want[p.Name] = true
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("expected redaction pattern %q not present", k)
		}
	}
}

// mustLoad is a tiny helper wrapping Load + t.Fatal for the canonical repo
// registries.
func mustLoad(t *testing.T) *Registry {
	t.Helper()
	r, err := Load(repoRegistries(t))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return r
}
