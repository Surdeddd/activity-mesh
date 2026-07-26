package redact

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"gopkg.in/yaml.v3"
)

// registries/redaction.yaml calls itself the canonical declaration of the pack
// while the runtime rules are compiled into the binary. Nothing keeps the two
// in step except this test: without it, widening a compiled rule silently makes
// the documented pack a lie for every other consumer (hooks, MCP, wiki tooling).
type yamlPack struct {
	SchemaVersion int `yaml:"schema_version"`
	Patterns      []struct {
		Name        string `yaml:"name"`
		Regex       string `yaml:"regex"`
		Replacement string `yaml:"replacement"`
		Group       int    `yaml:"group"`
	} `yaml:"patterns"`
	Tier2 struct {
		CandidateRegex string  `yaml:"candidate_regex"`
		MinEntropy     float64 `yaml:"min_entropy_bits_per_char"`
	} `yaml:"tier2"`
	Allowlist []struct {
		Name  string `yaml:"name"`
		Regex string `yaml:"regex"`
	} `yaml:"allowlist"`
}

// Patterns whose runtime regex is built from the environment and therefore has
// no fixed literal to compare against.
var dynamicPatterns = map[string]bool{
	"user_path":       true,
	"lowercase_prose": true,
}

func loadPack(t *testing.T) yamlPack {
	t.Helper()
	buf, err := os.ReadFile(filepath.Join("..", "..", "registries", "redaction.yaml"))
	if err != nil {
		t.Fatalf("read redaction.yaml: %v", err)
	}
	var p yamlPack
	if err := yaml.Unmarshal(buf, &p); err != nil {
		t.Fatalf("parse redaction.yaml: %v", err)
	}
	return p
}

func TestRedactionYAMLMatchesCompiledRules(t *testing.T) {
	pack := loadPack(t)

	if len(pack.Patterns) != len(rules) {
		t.Fatalf("redaction.yaml declares %d patterns, the binary compiles %d", len(pack.Patterns), len(rules))
	}
	for i, want := range pack.Patterns {
		got := rules[i]
		if want.Name != got.name {
			t.Errorf("pattern %d: yaml name %q, compiled name %q (order must match)", i, want.Name, got.name)
			continue
		}
		if want.Group != got.group {
			t.Errorf("pattern %q: yaml group %d, compiled group %d", want.Name, want.Group, got.group)
		}
		if dynamicPatterns[want.Name] {
			continue
		}
		if _, err := regexp.Compile(want.Regex); err != nil {
			t.Errorf("pattern %q: yaml regex does not compile: %v", want.Name, err)
			continue
		}
		if want.Regex != got.re.String() {
			t.Errorf("pattern %q drifted:\n yaml: %s\ncompiled: %s", want.Name, want.Regex, got.re.String())
		}
	}
}

func TestRedactionYAMLMatchesCompiledAllowlist(t *testing.T) {
	pack := loadPack(t)
	compiled := map[string]string{
		"uuid":       uuidRe.String(),
		"git_sha":    hex40Re.String(),
		"sha256_hex": hex64Re.String(),
		"ulid":       ulidRe.String(),
	}
	seen := map[string]bool{}
	for _, entry := range pack.Allowlist {
		seen[entry.Name] = true
		want, ok := compiled[entry.Name]
		if !ok {
			if !dynamicPatterns[entry.Name] {
				t.Errorf("allowlist %q is documented but not compiled in", entry.Name)
			}
			continue
		}
		if entry.Regex != want {
			t.Errorf("allowlist %q drifted:\n yaml: %s\ncompiled: %s", entry.Name, entry.Regex, want)
		}
	}
	for name := range compiled {
		if !seen[name] {
			t.Errorf("allowlist %q is compiled in but undocumented in redaction.yaml", name)
		}
	}
}

func TestRedactionYAMLDocumentsTier2(t *testing.T) {
	pack := loadPack(t)
	if pack.Tier2.CandidateRegex != base64Re.String() {
		t.Errorf("tier2 candidate regex drifted:\n yaml: %s\ncompiled: %s", pack.Tier2.CandidateRegex, base64Re.String())
	}
	if pack.Tier2.MinEntropy != minEntropy {
		t.Errorf("tier2 entropy floor drifted: yaml %v, compiled %v", pack.Tier2.MinEntropy, minEntropy)
	}
}
