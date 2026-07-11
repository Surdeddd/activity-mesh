package redact

import (
	"os"
	"strings"
	"testing"
)

func mustHome(t *testing.T) string {
	t.Helper()
	h, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("no home dir: %v", err)
	}
	return h
}

func TestTier1Patterns(t *testing.T) {
	cases := []struct {
		name            string
		positive        string
		negative        string
		marker          string
		negShouldRedact bool
	}{
		{
			name:     "anthropic_key",
			positive: "key=" + "sk-ant-api03-" + strings.Repeat("A", 93) + "AA more",
			negative: "talked about sk-ant briefly",
			marker:   "anthropic_key",
		},
		{
			name:     "github_classic",
			positive: "GH=ghp_" + strings.Repeat("a", 36) + " end",
			negative: "ghp prefix is too short ghp_abc",
			marker:   "github_token",
		},
		{
			name:     "aws_key",
			positive: "AKIAABCDEFGHIJKLMNOP rest",
			negative: "no real key here AKIA-short",
			marker:   "aws_access_key",
		},
		{
			name:     "slack_token",
			positive: "tok=xoxb-1234567890ab end",
			negative: "xox-only no dash",
			marker:   "slack_token",
		},
		{
			name:     "telegram_bot",
			positive: "bot 123456789:" + strings.Repeat("A", 35) + " ok",
			negative: "no telegram here",
			marker:   "telegram_bot",
		},
		{
			name:     "jwt",
			positive: "auth=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.QY5XCkNI8ZjAk9 ok",
			negative: "header eyJ short",
			marker:   "jwt",
		},
		{
			name:     "private_key",
			positive: "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----",
			negative: "talking about a private key",
			marker:   "private_key",
		},
		{
			name:     "db_url_postgres",
			positive: "DATABASE_URL=postgres://user:secretpw@host.example.com/db",
			negative: "use postgres in production",
			marker:   "db_url",
		},
		{
			name:     "user_path",
			positive: "the file is " + mustHome(t) + "/Projects/foo",
			negative: "/Users/somebody-else-entirely/Projects/foo",
			marker:   "user_path",
		},
		{
			name:     "lan_ip",
			positive: "ip 192.168.1.42",
			negative: "ip 8.8.8.8",
			marker:   "lan_ip",
		},
		{
			name:     "email",
			positive: "contact me at user@example.com",
			negative: "no email here at all",
			marker:   "email",
		},
		{
			name:     "eth_key",
			positive: "key 0x" + strings.Repeat("a", 64),
			negative: "short hex 0xdeadbeef",
			marker:   "eth_private_key",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, hits := Apply(tc.positive)
			if !strings.Contains(got, "[REDACTED:") {
				t.Errorf("positive case not redacted: %q -> %q", tc.positive, got)
			}
			found := false
			for _, h := range hits {
				if strings.Contains(h.PatternName, tc.marker) || strings.Contains(strings.ToLower(h.PatternName), strings.ToLower(tc.marker)) {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("no audit hit with marker %q in %+v", tc.marker, hits)
			}
			gotNeg, _ := Apply(tc.negative)
			if strings.Contains(gotNeg, "[REDACTED:"+tc.marker) {
				t.Errorf("negative case wrongly redacted: %q -> %q", tc.negative, gotNeg)
			}
		})
	}
}

func TestEntropyHeuristic(t *testing.T) {
	hi := "blob=YWxwaGFiZXRiZXRhZ2FtbWFkZWx0YWVwc2lsb24xMjM0NTY3ODkwQUJDREVGR0g end"
	out, hits := Apply(hi)
	if !strings.Contains(out, "[REDACTED:") {
		t.Errorf("expected high-entropy chunk to be redacted, got %q", out)
	}
	foundEntropy := false
	for _, h := range hits {
		if h.Kind == "entropy" {
			foundEntropy = true
		}
	}
	if !foundEntropy {
		t.Errorf("expected at least one entropy hit, got %+v", hits)
	}

	low := "the quick brown fox jumps over the lazy dog and continues running across town"
	got, _ := Apply(low)
	if strings.Contains(got, "[REDACTED:high_entropy") {
		t.Errorf("low-entropy English wrongly redacted: %q", got)
	}
}

func TestAllowlist(t *testing.T) {
	uuid := "uuid=550e8400-e29b-41d4-a716-446655440000 end"
	if !isAllowlisted("550e8400-e29b-41d4-a716-446655440000") {
		t.Fatalf("uuid expected allowlisted")
	}
	if got, _ := Apply(uuid); strings.Contains(got, "[REDACTED:") {
		t.Errorf("uuid redacted: %q", got)
	}
	sha := "commit=" + strings.Repeat("a", 40) + " end"
	if got, _ := Apply(sha); strings.Contains(got, "[REDACTED:high_entropy") {
		t.Errorf("git SHA redacted: %q", got)
	}
}

func TestApplyJSONNested(t *testing.T) {
	tree := map[string]any{
		"summary": "leak " + "sk-ant-api03-" + strings.Repeat("A", 93) + "AA",
		"tags":    []any{"ok", "user@test.com"},
		"meta": map[string]any{
			"path": mustHome(t) + "/foo",
		},
	}
	out, hits := ApplyJSON(tree)
	if len(hits) < 3 {
		t.Errorf("expected ≥3 hits across nested fields, got %d (%+v)", len(hits), hits)
	}
	m := out.(map[string]any)
	if !strings.Contains(m["summary"].(string), "[REDACTED:anthropic_key") {
		t.Errorf("summary not redacted: %v", m["summary"])
	}
	tags := m["tags"].([]any)
	if !strings.Contains(tags[1].(string), "[REDACTED:email") {
		t.Errorf("nested email not redacted: %v", tags[1])
	}
	meta := m["meta"].(map[string]any)
	if !strings.Contains(meta["path"].(string), "[REDACTED:user_path") {
		t.Errorf("nested path not redacted: %v", meta["path"])
	}
}

func TestEmptyAndPlain(t *testing.T) {
	if out, hits := Apply(""); out != "" || hits != nil {
		t.Errorf("empty input mutated: %q hits=%v", out, hits)
	}
	plain := "this is a normal sentence with no secrets"
	if out, hits := Apply(plain); out != plain || hits != nil {
		t.Errorf("plain text mutated: %q hits=%v", out, hits)
	}
}

func TestShannonEntropyMath(t *testing.T) {
	if shannon("aaaaaaaa") != 0 {
		t.Errorf("expected 0 entropy for repeated chars")
	}
	got := shannon("abababab")
	if got < 0.99 || got > 1.01 {
		t.Errorf("expected ≈1 bit/char, got %f", got)
	}
}
