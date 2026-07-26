package redact

import (
	"strings"
	"testing"
)

// Secrets that used to slip through — every case here is a value that was
// written to a shard in full or in part before the pattern pack was widened.
func TestTier1CoversPreviouslyMissedSecrets(t *testing.T) {
	cases := []struct {
		name   string
		input  string
		marker string
		// leak is a fragment of the secret that must not survive redaction.
		leak string
	}{
		{
			name:   "pgp_private_key_block",
			input:  "-----BEGIN PGP PRIVATE KEY BLOCK-----\nVersion: GnuPG\n\nlQOYBFsecretmaterial\n-----END PGP PRIVATE KEY BLOCK-----",
			marker: "private_key_pem",
			leak:   "lQOYBFsecretmaterial",
		},
		{
			name:   "openssh_private_key",
			input:  "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXkAAA\n-----END OPENSSH PRIVATE KEY-----",
			marker: "private_key_pem",
			leak:   "b3BlbnNzaC1rZXkAAA",
		},
		{
			name:   "oversized_slack_token_leaves_no_tail",
			input:  "tok=xoxp-1234567890-1234567890-1234567890-aB3xY9qWzT7mK2pL8nR4vC6hJ1sD5fG0bN2mQ8wE4rT6yU9iO3pA7sD1fG5hJ9kL end",
			marker: "slack_token",
			leak:   "yU9iO3pA7sD1fG5hJ9kL",
		},
		{
			name:   "telegram_bot_11_digit_id",
			input:  "TG=86256030671:AA" + strings.Repeat("x", 33) + " ok",
			marker: "telegram_bot",
			leak:   strings.Repeat("x", 33),
		},
		{
			name:   "redis_url_password",
			input:  "redis://default:s3cr3tpass@redis.local:6379",
			marker: "db_url",
			leak:   "s3cr3tpass",
		},
		{
			name:   "amqp_url_password",
			input:  "amqps://svc:p4ssw0rd@rabbit.internal:5671",
			marker: "db_url",
			leak:   "p4ssw0rd",
		},
		{
			name:   "https_basic_auth",
			input:  "https://user:passw0rd@example.com/path",
			marker: "db_url",
			leak:   "passw0rd",
		},
		{
			name:   "hex_signing_secret",
			input:  "SLACK_SIGNING_SECRET=8f742231b10e8888abcd991234567851",
			marker: "hex_secret",
			leak:   "8f742231b10e8888abcd991234567851",
		},
		{
			name:   "hex_auth_token",
			input:  "TWILIO_AUTH_TOKEN=0123456789abcdef0123456789abcdef",
			marker: "hex_secret",
			leak:   "0123456789abcdef0123456789abcdef",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := Apply(tc.input)
			if strings.Contains(out, tc.leak) {
				t.Errorf("secret fragment survived redaction:\n in: %s\nout: %s", tc.input, out)
			}
			found := false
			for _, h := range hits {
				if h.PatternName == tc.marker {
					found = true
				}
			}
			if !found {
				t.Errorf("no %q hit recorded (hits=%v, out=%q)", tc.marker, hits, out)
			}
		})
	}
}

// The context rule must keep the variable name — the name is not the secret and
// losing it makes the shard unreadable.
func TestHexSecretKeepsVariableName(t *testing.T) {
	out, _ := Apply("TWILIO_AUTH_TOKEN=0123456789abcdef0123456789abcdef done")
	if !strings.HasPrefix(out, "TWILIO_AUTH_TOKEN=[REDACTED:hex_secret:32]") {
		t.Errorf("got %q, want the name preserved and only the value redacted", out)
	}
	if !strings.HasSuffix(out, " done") {
		t.Errorf("trailing context lost: %q", out)
	}
}

// Bare hashes are content addresses, not secrets: redacting them would make
// commit refs and checksums useless.
func TestHexSecretDoesNotEatBareHashes(t *testing.T) {
	for _, s := range []string{
		"commit 356a192b7913b04c54574d18c28d46e6395428ab landed",
		"sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"blob 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
	} {
		if out, hits := Apply(s); out != s {
			t.Errorf("false positive on %q -> %q (hits=%v)", s, out, hits)
		}
	}
}

// A secret used as a JSON object key is still a secret on disk.
func TestApplyJSONRedactsObjectKeys(t *testing.T) {
	token := "ghp_" + strings.Repeat("z", 36)
	cleaned, hits := ApplyJSON(map[string]any{
		"summary": "env dump",
		"env":     map[string]any{token: "prod"},
	})
	m, ok := cleaned.(map[string]any)
	if !ok {
		t.Fatalf("ApplyJSON returned %T, want map", cleaned)
	}
	env, ok := m["env"].(map[string]any)
	if !ok {
		t.Fatalf("env is %T, want map", m["env"])
	}
	for k := range env {
		if strings.Contains(k, token) {
			t.Errorf("token survived as a JSON key: %q", k)
		}
	}
	if len(env) != 1 {
		t.Errorf("key count changed: %v", env)
	}
	if len(hits) == 0 {
		t.Error("no hit recorded for the redacted key")
	}
}

// Two keys that redact to the same placeholder must not collapse into one.
func TestApplyJSONKeyCollisionKeepsBothEntries(t *testing.T) {
	a := "ghp_" + strings.Repeat("a", 36)
	b := "ghp_" + strings.Repeat("b", 36)
	cleaned, _ := ApplyJSON(map[string]any{a: 1, b: 2})
	m := cleaned.(map[string]any)
	if len(m) != 2 {
		t.Errorf("collision collapsed entries: %v", m)
	}
}

// Redaction must be a fixed point: re-running it over its own output changes
// nothing, otherwise redact-shard would rewrite the shard on every pass.
func TestApplyIsIdempotentAcrossNewRules(t *testing.T) {
	inputs := []string{
		"redis://default:s3cr3tpass@redis.local:6379",
		"SLACK_SIGNING_SECRET=8f742231b10e8888abcd991234567851",
		"-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n-----END PGP PRIVATE KEY BLOCK-----",
		"TG=86256030671:AA" + strings.Repeat("x", 33),
	}
	for _, in := range inputs {
		once, _ := Apply(in)
		twice, _ := Apply(once)
		if once != twice {
			t.Errorf("not idempotent:\n1st: %q\n2nd: %q", once, twice)
		}
	}
}
