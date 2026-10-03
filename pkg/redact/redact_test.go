package redact

import (
	"fmt"
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

func TestUserPathRedactsNonASCIIHome(t *testing.T) {
	for _, home := range []string{`/home/максим`, `C:\Users\Максим`, `/Users/josé`} {
		t.Run(home, func(t *testing.T) {
			useHomes(t, home)
			sep := "/"
			if strings.HasPrefix(home, "C:") {
				sep = `\`
			}
			in := "wrote " + home + sep + "notes.md"
			if out, hits := Apply(in); len(hits) == 0 {
				t.Fatalf("no user_path hit for home %q in %q (out=%q)", home, in, out)
			}
		})
	}
}

func TestHexSecretBehindQuotedKeyIsRedacted(t *testing.T) {
	secret := "8f742231b10e8888abcd991234567851"
	for _, in := range []string{
		`config {"SLACK_SIGNING_SECRET": "` + secret + `"}`,
		`env {'auth_token': '` + secret + `'}`,
	} {
		out, hits := Apply(in)
		if strings.Contains(out, secret) {
			t.Errorf("hex secret behind a quoted key survived: %q (hits=%v)", out, hits)
		}
	}
	cleaned, _ := ApplyJSON(map[string]any{"env": map[string]any{"SLACK_SIGNING_SECRET": secret}})
	if v := cleaned.(map[string]any)["env"].(map[string]any)["SLACK_SIGNING_SECRET"]; v == secret {
		t.Errorf("hex secret as a structured /push field survived: SLACK_SIGNING_SECRET=%v", v)
	}
}

func TestGitRemoteIsNotRedactedAsEmail(t *testing.T) {
	in := "pushed to git@github.com:Surdeddd/activity-mesh.git"
	if out, hits := Apply(in); out != in {
		t.Errorf("git remote mangled as PII: %q -> %q (hits=%v)", in, out, hits)
	}
}

func TestHexSecretLongerThan64IsRedacted(t *testing.T) {
	secret := "9f2c4e7a1b3d5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8" +
		"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
	for _, in := range []string{
		"SECRET_KEY_BASE=" + secret,
		"API_KEY=" + secret[:65],
	} {
		out, hits := Apply(in)
		if strings.Contains(out, secret[:65]) {
			t.Errorf("hex secret bound to a secret-ish name survived: %q (hits=%v)", out, hits)
		}
	}
}

func useHomes(t *testing.T, homes string) {
	t.Helper()
	useHome(t, t.TempDir(), homes)
}

func useHome(t *testing.T, home, homes string) {
	t.Helper()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("ACTIVITY_MESH_REDACT_HOMES", homes)
	r := ruleNamed("user_path")
	prev := r.find
	r.find = homeSpans(userHomes())
	t.Cleanup(func() { r.find = prev })
}

func TestUserPathRedactsOnlyTheHome(t *testing.T) {
	const (
		jose    = "/Users/josé"
		maxim   = "/home/максим"
		bob     = "/home/bob"
		bobby   = "/home/bobby"
		maxHome = "/Users/max"
		extHome = "/Volumes/ext"
	)
	red := func(home string) string { return fmt.Sprintf("[REDACTED:user_path:%d]", len(home)) }
	cases := []struct {
		name, homes, in, want string
		hits                  int
	}{
		{"slash after", jose, "opened " + jose + "/notes.md", "opened " + red(jose) + "/notes.md", 1},
		{"end of text", jose, "cwd=" + jose, "cwd=" + red(jose), 1},
		{"punctuation after", maxim, "ls " + maxim + ", then quit", "ls " + red(maxim) + ", then quit", 1},
		{"two homes in a path list", jose, "PATH=" + jose + "/bin:" + jose + "/.local/bin", "PATH=" + red(jose) + "/bin:" + red(jose) + "/.local/bin", 2},
		{"longer name, non-ASCII letter", jose, "see " + jose + "ñ/x", "see " + jose + "ñ/x", 0},
		{"longer name, ASCII letter", jose, "see " + jose + "a/x", "see " + jose + "a/x", 0},
		{"longer name, digit", jose, "see " + jose + "2/x", "see " + jose + "2/x", 0},
		{"longer name, underscore", jose, "see " + jose + "_old/x", "see " + jose + "_old/x", 0},
		{"CJK glued after an ASCII home", bob, "文件在" + bob + "中", "文件在" + red(bob) + "中", 1},
		{"Cyrillic glued after an ASCII home", bob, "лежит в " + bob + "папке", "лежит в " + red(bob) + "папке", 1},
		{"Japanese glued after an ASCII home", maxHome, "ファイルは" + maxHome + "にあります", "ファイルは" + red(maxHome) + "にあります", 1},
		{"fullwidth digit glued after an ASCII home", bob, "x " + bob + "３個", "x " + red(bob) + "３個", 1},
		{"longer ASCII name when only the shorter home is configured", bob, "see " + bobby + "/x", "see " + bobby + "/x", 0},
		{"longest configured home wins", bob + ":" + bobby, "see " + bobby + "/x", "see " + red(bobby) + "/x", 1},
		{"the same home twice in a row", bob, "stat " + bob + bob + "/.config", "stat " + red(bob) + red(bob) + "/.config", 2},
		{"two different homes in a row", maxHome + ":" + extHome, maxHome + extHome + "/f", red(maxHome) + red(extHome) + "/f", 2},
		{"nested home does not shadow the primary one", maxHome + ":" + maxHome + "/work", maxHome + "/workshop/x", red(maxHome) + "/workshop/x", 1},
		{"nested home wins as a whole path component", maxHome + ":" + maxHome + "/work", maxHome + "/work/x", red(maxHome+"/work") + "/x", 1},
		{"nested home extended by a hyphen does not shadow the shorter one", bob + ":" + bob + "-work", "see " + bob + "-worksee", "see " + red(bob) + "-worksee", 1},
		{"nested home extended by a hyphen wins as a whole name", bob + ":" + bob + "-work", "see " + bob + "-work/x", "see " + red(bob+"-work") + "/x", 1},
		{"primary home survives a rejected nested home ending in a Cyrillic letter", maxHome + ":" + maxHome + "/проект", maxHome + "/проекты/notes.md", red(maxHome) + "/проекты/notes.md", 1},
		{"primary home survives a rejected nested home followed by a digit", maxHome + ":" + maxHome + "/проект", maxHome + "/проект2/x", red(maxHome) + "/проект2/x", 1},
		{"primary home survives a rejected nested home followed by an underscore", maxHome + ":" + maxHome + "/проект", maxHome + "/проект_old/x", red(maxHome) + "/проект_old/x", 1},
		{"primary non-ASCII home survives a rejected nested home", jose + ":" + jose + "/Проекты", jose + "/Проектыx/f", red(jose) + "/Проектыx/f", 1},
		{"primary Cyrillic home survives a rejected nested home", maxim + ":" + maxim + "/проект", maxim + "/проекты/x", red(maxim) + "/проекты/x", 1},
		{"inner home survives a rejected longer home that contains it", bob + ":/mnt/home/bob/жж", "/mnt/home/bob/жжa/x", "/mnt" + red(bob) + "/жжa/x", 1},
		{"overlapping homes merge into one span", maxHome + ":" + maxHome + "/work:/work/acme", maxHome + "/work/acme/x", red(maxHome+"/work/acme") + "/x", 1},
		{"a chain of overlapping homes is one span", "/a/b:/b/c:/c/d", "/a/b/c/d/x", "[REDACTED:user_path:8]/x", 1},
		{"invalid UTF-8 after an ASCII home", bob, bob + "\xff/x", red(bob) + "\xff/x", 1},
		{"invalid UTF-8 after a non-ASCII home", jose, jose + "\xff/x", red(jose) + "\xff/x", 1},
		{"home that trims to nothing", "//", "plain text /tmp/x", "plain text /tmp/x", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			useHomes(t, tc.homes)
			got, hits := Apply(tc.in)
			if got != tc.want {
				t.Errorf("Apply(%q)\n got: %q\nwant: %q", tc.in, got, tc.want)
			}
			if len(hits) != tc.hits {
				t.Errorf("got %d hits, want %d: %+v", len(hits), tc.hits, hits)
			}
		})
	}
}

func TestUserPathRedactsWindowsStyleHomeFromTheEnvironment(t *testing.T) {
	const home = `C:\Users\Максим`
	useHome(t, home, "")
	got, hits := Apply(`wrote ` + home + `\notes.md`)
	want := fmt.Sprintf(`wrote [REDACTED:user_path:%d]\notes.md`, len(home))
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if len(hits) != 1 {
		t.Errorf("got %d hits, want 1: %+v", len(hits), hits)
	}
}

func TestUserPathUnionOfPrimaryAndExtraHomes(t *testing.T) {
	useHome(t, "/Users/max", "/Users/max/work:/work/acme")
	got, hits := Apply("/Users/max/work/acme/x")
	want := "[REDACTED:user_path:20]/x"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if len(hits) != 1 {
		t.Errorf("got %d hits, want 1: %+v", len(hits), hits)
	}
}

func TestUserPathRedactsConfiguredHomeWithInvalidUTF8(t *testing.T) {
	const home = "/home/b\xffb"
	r := &rule{name: "user_path", kind: "env", repType: "user_path", find: homeSpans([]string{home})}
	var hits []Hit
	got := replaceSpans("see "+home+"/x", r, &hits)
	want := fmt.Sprintf("see [REDACTED:user_path:%d]/x", len(home))
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if len(hits) != 1 {
		t.Errorf("got %d hits, want 1: %+v", len(hits), hits)
	}
}

func TestHomeSpansIgnoresEmptyHome(t *testing.T) {
	got := homeSpans([]string{"", "/home/bob"})("x /home/bob/y")
	if len(got) != 1 || got[0] != (span{2, 11}) {
		t.Errorf("got %v, want one span {2 11}", got)
	}
}

func TestHexSecretKeepsNameQuotesAndTail(t *testing.T) {
	secret := "8f742231b10e8888abcd991234567851"
	long := strings.Repeat("0f1e2d3c4b5a6978", 8)
	cases := []struct{ name, in, want string }{
		{"json double quotes", `{"SLACK_SIGNING_SECRET": "` + secret + `"}`, `{"SLACK_SIGNING_SECRET": "[REDACTED:hex_secret:32]"}`},
		{"dict single quotes", `env {'auth_token': '` + secret + `'}`, `env {'auth_token': '[REDACTED:hex_secret:32]'}`},
		{"space before colon", `"api_key" : "` + secret + `"`, `"api_key" : "[REDACTED:hex_secret:32]"`},
		{"key base suffix", "SECRET_KEY_BASE=" + secret + " end", "SECRET_KEY_BASE=[REDACTED:hex_secret:32] end"},
		{"128 hex digits", "API_KEY=" + long, "API_KEY=[REDACTED:hex_secret:128]"},
		{"name is not secret-ish", `{"request_id": "` + secret + `"}`, `{"request_id": "` + secret + `"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, _ := Apply(tc.in)
			if out != tc.want {
				t.Errorf("Apply(%q)\n got: %q\nwant: %q", tc.in, out, tc.want)
			}
			if again, _ := Apply(out); again != out {
				t.Errorf("not idempotent:\n1st: %q\n2nd: %q", out, again)
			}
		})
	}
}

func TestSSHRemoteKeptWhileRealEmailsAreRedacted(t *testing.T) {
	cases := []struct {
		name, in, want string
		hits           int
	}{
		{"remote then email", "pushed to git@github.com:owner/repo.git, cc alice@example.com", "pushed to git@github.com:owner/repo.git, cc [REDACTED:email:17]", 1},
		{"email then remote", "alice@example.com cloned git@gitlab.example.org:team/sub-group/repo.git", "[REDACTED:email:17] cloned git@gitlab.example.org:team/sub-group/repo.git", 1},
		{"only remotes", "origin git@github.com:a/b.git, upstream git@github.com:c/d.git", "origin git@github.com:a/b.git, upstream git@github.com:c/d.git", 0},
		{"colon without a path", "ping bob@example.com: are you there", "ping [REDACTED:email:15]: are you there", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := Apply(tc.in)
			if out != tc.want {
				t.Errorf("Apply(%q)\n got: %q\nwant: %q", tc.in, out, tc.want)
			}
			if len(hits) != tc.hits {
				t.Errorf("got %d hits, want %d: %+v", len(hits), tc.hits, hits)
			}
		})
	}
}

func TestSSHRemoteExemptionIsLimitedToGit(t *testing.T) {
	cases := []struct {
		name, in, want string
		hits           int
	}{
		{"git remote", "git@github.com:owner/repo.git", "git@github.com:owner/repo.git", 0},
		{"git remote in upper case", "GIT@GitHub.com:Owner/Repo.git", "GIT@GitHub.com:Owner/Repo.git", 0},
		{"person at a corporate host", "jane.doe@corp.example.com:docs/x", "[REDACTED:email:25]:docs/x", 1},
		{"user at a lan host", "maxim@mac-mini.local:repo/x", "[REDACTED:email:20]:repo/x", 1},
		{"local part only ends with git", "foogit@github.com:owner/repo.git", "[REDACTED:email:17]:owner/repo.git", 1},
		{"local part ends with a dotted git", "x.git@github.com:owner/repo.git", "[REDACTED:email:16]:owner/repo.git", 1},
		{"git after a dash is a longer local part", "-git@corp.example.com:docs/x", "-[REDACTED:email:20]:docs/x", 1},
		{"git after a dot is a longer local part", ".git@corp.example.com:docs/x", ".[REDACTED:email:20]:docs/x", 1},
		{"git user without a path", "git@example.com:thanks", "[REDACTED:email:15]:thanks", 1},
		{"plain email, colon and text without a slash", "bob@example.com:thanks", "[REDACTED:email:15]:thanks", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, hits := Apply(tc.in)
			if out != tc.want {
				t.Errorf("Apply(%q)\n got: %q\nwant: %q", tc.in, out, tc.want)
			}
			if len(hits) != tc.hits {
				t.Errorf("got %d hits, want %d: %+v", len(hits), tc.hits, hits)
			}
		})
	}
}

func TestApplyJSONRedactsHexValueUnderSecretKey(t *testing.T) {
	secret := "8f742231b10e8888abcd991234567851"
	redacted := func(n int) string { return fmt.Sprintf("[REDACTED:hex_secret:%d]", n) }
	cases := []struct {
		name  string
		key   string
		value any
		want  any
		hits  int
	}{
		{"signing secret", "SLACK_SIGNING_SECRET", secret, redacted(32), 1},
		{"hyphenated api key", "x-api-key", secret, redacted(32), 1},
		{"key base suffix", "SECRET_KEY_BASE", secret, redacted(32), 1},
		{"upper-case hex", "Password", strings.ToUpper(secret), redacted(32), 1},
		{"hex longer than 64", "auth_token", strings.Repeat(secret, 3), redacted(96), 1},
		{"key is not secret-ish", "request_id", secret, secret, 0},
		{"keyword is not the last word", "token_count", secret, secret, 0},
		{"hex shorter than 32", "api_key", secret[:31], secret[:31], 0},
		{"value is not hex", "api_key", "changeme", "changeme", 0},
		{"value is not a string", "api_key", float64(42), float64(42), 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cleaned, hits := ApplyJSON(map[string]any{"env": map[string]any{tc.key: tc.value}})
			got := cleaned.(map[string]any)["env"].(map[string]any)[tc.key]
			if got != tc.want {
				t.Errorf("%s = %v, want %v", tc.key, got, tc.want)
			}
			if len(hits) != tc.hits {
				t.Fatalf("got %d hits, want %d: %+v", len(hits), tc.hits, hits)
			}
			for _, h := range hits {
				if h.PatternName != "hex_secret" || h.Kind != "credential" || h.LenRedacted != len(tc.value.(string)) {
					t.Errorf("unexpected hit %+v", h)
				}
			}
		})
	}
}
