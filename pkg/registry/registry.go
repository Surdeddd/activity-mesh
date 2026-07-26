package registry

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

const supportedSchemaVersion = 1

const (
	StatusActive     = "active"
	StatusDeprecated = "deprecated"
	StatusArchived   = "archived"
)

type KindsFile struct {
	SchemaVersion int                 `yaml:"schema_version"`
	Core          []Kind              `yaml:"core"`
	Extensions    map[string]KindMeta `yaml:"extensions"`
}

type Kind struct {
	Name            string `yaml:"name"`
	Description     string `yaml:"description"`
	SeverityDefault string `yaml:"severity_default"`
	PushChannel     string `yaml:"push_channel,omitempty"`
}

type KindMeta struct {
	Description string `yaml:"description"`
	Severity    string `yaml:"severity"`
	PushChannel string `yaml:"push_channel,omitempty"`
}

type ScopesFile struct {
	SchemaVersion int     `yaml:"schema_version"`
	Scopes        []Scope `yaml:"scopes"`
}

type Scope struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	Status      string `yaml:"status"`
	Created     string `yaml:"created,omitempty"`
	Expires     string `yaml:"expires,omitempty"`
	Replaces    string `yaml:"replaces,omitempty"`
	ReplacedBy  string `yaml:"replaced_by,omitempty"`
	Router      *bool  `yaml:"router,omitempty"`
}

func (s Scope) RouterEnabled() bool { return s.Router == nil || *s.Router }

type AgentsFile struct {
	SchemaVersion int     `yaml:"schema_version"`
	Agents        []Agent `yaml:"agents"`
}

type Agent struct {
	ID                    string   `yaml:"id"`
	Description           string   `yaml:"description,omitempty"`
	Runtime               string   `yaml:"runtime,omitempty"`
	Host                  string   `yaml:"host,omitempty"`
	Status                string   `yaml:"status"`
	ExpectedSilence       bool     `yaml:"expected_silence"`
	SilenceThresholdHours int      `yaml:"silence_threshold_hours,omitempty"`
	ArchivedAt            string   `yaml:"archived_at,omitempty"`
	Reason                string   `yaml:"reason,omitempty"`
	Aliases               []string `yaml:"aliases,omitempty"`
	WeakAliases           []string `yaml:"weak_aliases,omitempty"`
}

type RedactionFile struct {
	SchemaVersion int                `yaml:"schema_version"`
	Patterns      []RedactionPattern `yaml:"patterns"`
	Allowlist     []RedactionPattern `yaml:"allowlist"`
}

type RedactionPattern struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description,omitempty"`
	Kind        string `yaml:"kind,omitempty"`
	Regex       string `yaml:"regex"`
	Replacement string `yaml:"replacement,omitempty"`
	// Group > 0 documents that only that capture group of the match is redacted.
	Group int `yaml:"group,omitempty"`
}

type Registry struct {
	Kinds     KindsFile
	Scopes    ScopesFile
	Agents    AgentsFile
	Redaction RedactionFile

	kindByName  map[string]Kind
	extByName   map[string]KindMeta
	scopeByName map[string]Scope
	agentByID   map[string]Agent
}

func Load(rootDir string) (*Registry, error) {
	r := &Registry{}
	if err := loadYAML(filepath.Join(rootDir, "kinds.yaml"), &r.Kinds); err != nil {
		return nil, fmt.Errorf("kinds.yaml: %w", err)
	}
	if err := loadYAML(filepath.Join(rootDir, "scopes.yaml"), &r.Scopes); err != nil {
		return nil, fmt.Errorf("scopes.yaml: %w", err)
	}
	if err := loadYAML(filepath.Join(rootDir, "agents.yaml"), &r.Agents); err != nil {
		return nil, fmt.Errorf("agents.yaml: %w", err)
	}
	if err := loadYAML(filepath.Join(rootDir, "redaction.yaml"), &r.Redaction); err != nil {
		return nil, fmt.Errorf("redaction.yaml: %w", err)
	}
	if err := r.validate(); err != nil {
		return nil, err
	}
	r.buildIndexes()
	return r, nil
}

func LoadFromBytes(kinds, scopes, agents, redaction []byte) (*Registry, error) {
	r := &Registry{}
	if len(kinds) > 0 {
		if err := yaml.Unmarshal(kinds, &r.Kinds); err != nil {
			return nil, fmt.Errorf("kinds: %w", err)
		}
	}
	if len(scopes) > 0 {
		if err := yaml.Unmarshal(scopes, &r.Scopes); err != nil {
			return nil, fmt.Errorf("scopes: %w", err)
		}
	}
	if len(agents) > 0 {
		if err := yaml.Unmarshal(agents, &r.Agents); err != nil {
			return nil, fmt.Errorf("agents: %w", err)
		}
	}
	if len(redaction) > 0 {
		if err := yaml.Unmarshal(redaction, &r.Redaction); err != nil {
			return nil, fmt.Errorf("redaction: %w", err)
		}
	}
	if err := r.validate(); err != nil {
		return nil, err
	}
	r.buildIndexes()
	return r, nil
}

func LoadScopesFile(path string) (*Registry, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return LoadFromBytes(nil, buf, nil, nil)
}

func LoadAgentsFile(path string) (*Registry, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return LoadFromBytes(nil, nil, buf, nil)
}

func loadYAML(path string, target any) error {
	buf, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return yaml.Unmarshal(buf, target)
}

func (r *Registry) validate() error {
	if r.Kinds.SchemaVersion != 0 && r.Kinds.SchemaVersion != supportedSchemaVersion {
		return fmt.Errorf("kinds: unsupported schema_version %d (want %d)", r.Kinds.SchemaVersion, supportedSchemaVersion)
	}
	if r.Scopes.SchemaVersion != 0 && r.Scopes.SchemaVersion != supportedSchemaVersion {
		return fmt.Errorf("scopes: unsupported schema_version %d", r.Scopes.SchemaVersion)
	}
	if r.Agents.SchemaVersion != 0 && r.Agents.SchemaVersion != supportedSchemaVersion {
		return fmt.Errorf("agents: unsupported schema_version %d", r.Agents.SchemaVersion)
	}
	if r.Redaction.SchemaVersion != 0 && r.Redaction.SchemaVersion != supportedSchemaVersion {
		return fmt.Errorf("redaction: unsupported schema_version %d", r.Redaction.SchemaVersion)
	}
	// Duplicates used to resolve last-wins, so appending an `active` entry for a
	// name already archived (a plausible two-host merge artifact in the synced
	// scopes.yaml) silently re-opened emits to it. Fail loudly instead.
	seenScope := map[string]bool{}
	for _, s := range r.Scopes.Scopes {
		if !validStatus(s.Status) {
			return fmt.Errorf("scope %q: invalid status %q", s.Name, s.Status)
		}
		if seenScope[s.Name] {
			return fmt.Errorf("scope %q is declared more than once — resolve the duplicate", s.Name)
		}
		seenScope[s.Name] = true
	}
	seenAgent := map[string]bool{}
	for _, a := range r.Agents.Agents {
		if !validStatus(a.Status) {
			return fmt.Errorf("agent %q: invalid status %q", a.ID, a.Status)
		}
		if seenAgent[a.ID] {
			return fmt.Errorf("agent %q is declared more than once — resolve the duplicate", a.ID)
		}
		seenAgent[a.ID] = true
	}
	seenKind := map[string]bool{}
	for _, k := range r.Kinds.Core {
		if !validSeverity(k.SeverityDefault) {
			return fmt.Errorf("kind %q: invalid severity_default %q", k.Name, k.SeverityDefault)
		}
		if seenKind[k.Name] {
			return fmt.Errorf("kind %q is declared more than once — resolve the duplicate", k.Name)
		}
		seenKind[k.Name] = true
	}
	for ek := range r.Kinds.Extensions {
		if seenKind[ek] {
			return fmt.Errorf("kind %q is declared both as core and as an extension", ek)
		}
	}
	for ek, em := range r.Kinds.Extensions {
		if em.Severity != "" && !validSeverity(em.Severity) {
			return fmt.Errorf("ext kind %q: invalid severity %q", ek, em.Severity)
		}
	}
	return nil
}

func (r *Registry) buildIndexes() {
	r.kindByName = make(map[string]Kind, len(r.Kinds.Core))
	for _, k := range r.Kinds.Core {
		r.kindByName[k.Name] = k
	}
	r.extByName = make(map[string]KindMeta, len(r.Kinds.Extensions))
	for k, v := range r.Kinds.Extensions {
		r.extByName[k] = v
	}
	r.scopeByName = make(map[string]Scope, len(r.Scopes.Scopes))
	for _, s := range r.Scopes.Scopes {
		r.scopeByName[s.Name] = s
	}
	r.agentByID = make(map[string]Agent, len(r.Agents.Agents))
	for _, a := range r.Agents.Agents {
		r.agentByID[a.ID] = a
	}
}

func (r *Registry) IsValidKind(name string) bool {
	if _, ok := r.kindByName[name]; ok {
		return true
	}
	if _, ok := r.extByName[name]; ok {
		return true
	}
	return false
}

func (r *Registry) IsValidScope(name string) bool {
	_, ok := r.scopeByName[name]
	return ok
}

func (r *Registry) CanEmitToScope(name string) (bool, string) {
	s, ok := r.scopeByName[name]
	if !ok {
		return true, ""
	}
	switch s.Status {
	case StatusActive:
		return true, ""
	case StatusDeprecated:
		w := fmt.Sprintf("scope %q is deprecated", name)
		if s.ReplacedBy != "" {
			w += fmt.Sprintf(" (replaced_by: %s)", s.ReplacedBy)
		}
		return true, w
	case StatusArchived:
		return false, fmt.Sprintf("scope %q is archived (refusing new emits)", name)
	}
	return true, ""
}

func (r *Registry) GetAgent(id string) (Agent, bool) {
	a, ok := r.agentByID[id]
	return a, ok
}

func (r *Registry) GetScope(name string) (Scope, bool) {
	s, ok := r.scopeByName[name]
	return s, ok
}

func (r *Registry) GetKind(name string) (Kind, KindMeta, bool, string) {
	if k, ok := r.kindByName[name]; ok {
		return k, KindMeta{}, true, "core"
	}
	if m, ok := r.extByName[name]; ok {
		return Kind{}, m, true, "ext"
	}
	return Kind{}, KindMeta{}, false, ""
}

func (r *Registry) ActiveScopes() []Scope {
	out := make([]Scope, 0, len(r.Scopes.Scopes))
	for _, s := range r.Scopes.Scopes {
		if s.Status == StatusActive {
			out = append(out, s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (r *Registry) RouterScopes() []Scope {
	active := r.ActiveScopes()
	out := make([]Scope, 0, len(active))
	for _, s := range active {
		if s.RouterEnabled() {
			out = append(out, s)
		}
	}
	return out
}

func (r *Registry) ActiveAgents() []Agent {
	out := make([]Agent, 0, len(r.Agents.Agents))
	for _, a := range r.Agents.Agents {
		if a.Status == StatusActive {
			out = append(out, a)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (r *Registry) ExpectsHeartbeat(id string) bool {
	a, ok := r.agentByID[id]
	if !ok {
		return false
	}
	if a.Status != StatusActive {
		return false
	}
	return !a.ExpectedSilence
}

func validStatus(s string) bool {
	switch s {
	case StatusActive, StatusDeprecated, StatusArchived:
		return true
	}
	return false
}

func validSeverity(s string) bool {
	switch strings.ToUpper(s) {
	case "P0", "P1", "P2", "P3":
		return true
	}
	return false
}

// EnforceEmit validates kind and scope against the registries published in
// syncDir. A registry that is absent means validation is simply off; a registry
// that exists but cannot be read or parsed is an error, never a silent skip —
// a gate that fails open is not a gate. warn carries a non-fatal notice (a
// deprecated scope) that the caller should surface.
//
// Both write paths share this: emit enforced it while /push did not, so an
// archived scope stayed writable over HTTP.
func EnforceEmit(syncDir, kind, scope string) (warn string, err error) {
	buf, present, err := readIfPresent(filepath.Join(syncDir, "kinds.yaml"))
	if err != nil {
		return "", err
	}
	if present {
		reg, lerr := LoadFromBytes(buf, nil, nil, nil)
		if lerr != nil {
			return "", fmt.Errorf("kinds.yaml is present but invalid: %w", lerr)
		}
		// Namespaced org/name extensions are always allowed.
		if !reg.IsValidKind(kind) && !strings.Contains(kind, "/") {
			return "", fmt.Errorf("kind %q is not in the kinds registry (namespaced org/name extensions are always allowed)", kind)
		}
	}
	buf, present, err = readIfPresent(filepath.Join(syncDir, "scopes.yaml"))
	if err != nil {
		return "", err
	}
	if present {
		reg, lerr := LoadFromBytes(nil, buf, nil, nil)
		if lerr != nil {
			return "", fmt.Errorf("scopes.yaml is present but invalid: %w", lerr)
		}
		allowed, msg := reg.CanEmitToScope(scope)
		if !allowed {
			return "", fmt.Errorf("scope %q refuses new events: %s", scope, msg)
		}
		return msg, nil
	}
	return "", nil
}

func readIfPresent(path string) ([]byte, bool, error) {
	buf, err := os.ReadFile(path)
	switch {
	case err == nil:
		return buf, true, nil
	case errors.Is(err, os.ErrNotExist):
		return nil, false, nil
	default:
		return nil, false, fmt.Errorf("%s exists but is unreadable: %w", filepath.Base(path), err)
	}
}
