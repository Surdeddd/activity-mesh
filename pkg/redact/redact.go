package redact

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
)

type Hit struct {
	Kind          string `json:"kind"`           // pattern category (e.g. "anthropic_key")
	PatternName   string `json:"pattern_name"`   // human-readable label
	LenRedacted   int    `json:"len_redacted"`   // length of original secret
	SHA256First12 string `json:"sha256_first12"` // first 12 hex chars of sha256(secret)
}

type rule struct {
	name    string
	kind    string
	re      *regexp.Regexp
	repType string // short tag used in [REDACTED:<repType>:<len>]
}

var rules = []*rule{
	{
		name:    "anthropic_key",
		kind:    "credential",
		repType: "anthropic_key",
		re:      regexp.MustCompile(`sk-ant-(?:api03|admin01|oat01)-[A-Za-z0-9_\-]{93}AA`),
	},
	{
		name:    "openai_key",
		kind:    "credential",
		repType: "openai_key",
		re:      regexp.MustCompile(`\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,200}`),
	},
	{
		name:    "github_token",
		kind:    "credential",
		repType: "github_token",
		re:      regexp.MustCompile(`\b(?:gh[posur]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82})\b`),
	},
	{
		name:    "gitlab_token",
		kind:    "credential",
		repType: "gitlab_token",
		re:      regexp.MustCompile(`\bglpat-[A-Za-z0-9_\-]{20,}\b`),
	},
	{
		name:    "google_api_key",
		kind:    "credential",
		repType: "google_api_key",
		re:      regexp.MustCompile(`\bAIza[0-9A-Za-z_\-]{35}\b`),
	},
	{
		name:    "stripe_key",
		kind:    "credential",
		repType: "stripe_key",
		re:      regexp.MustCompile(`\b[rs]k_(?:live|test)_[A-Za-z0-9]{24,99}\b`),
	},
	{
		name:    "huggingface_token",
		kind:    "credential",
		repType: "hf_token",
		re:      regexp.MustCompile(`\bhf_[A-Za-z0-9]{30,}\b`),
	},
	{
		name:    "npm_token",
		kind:    "credential",
		repType: "npm_token",
		re:      regexp.MustCompile(`\bnpm_[A-Za-z0-9]{36}\b`),
	},
	{
		name:    "aws_access_key",
		kind:    "credential",
		repType: "aws_key",
		re:      regexp.MustCompile(`\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\b`),
	},
	{
		name:    "slack_token",
		kind:    "credential",
		repType: "slack_token",
		re:      regexp.MustCompile(`xox[abrsp]-[A-Za-z0-9-]{10,72}`),
	},
	{
		name:    "telegram_bot",
		kind:    "credential",
		repType: "telegram_bot",
		re:      regexp.MustCompile(`\b\d{9,10}:[A-Za-z0-9_\-]{35}\b`),
	},
	{
		name:    "jwt",
		kind:    "credential",
		repType: "jwt",
		re:      regexp.MustCompile(`eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9._+/=\-]+`),
	},
	{
		name:    "private_key_pem",
		kind:    "credential",
		repType: "private_key",
		re:      regexp.MustCompile(`(?s)-----BEGIN (?:RSA |OPENSSH |EC |DSA |PGP |ENCRYPTED )?PRIVATE KEY-----.+?-----END[^-]+-----`),
	},
	{
		name:    "db_url",
		kind:    "credential",
		repType: "db_url",
		re:      regexp.MustCompile(`(?:postgres|mysql|mongodb)(?:\+srv)?://[^:\s]+:[^@\s]+@[^\s/]+`),
	},
	{
		name:    "eth_private_key",
		kind:    "credential",
		repType: "eth_key",
		re:      regexp.MustCompile(`\b0x[a-fA-F0-9]{64}\b`),
	},
	{
		name:    "btc_address",
		kind:    "pii",
		repType: "btc_addr",
		re:      regexp.MustCompile(`\bbc1[a-z0-9]{39,59}\b`),
	},
	{
		name:    "email",
		kind:    "pii",
		repType: "email",
		re:      regexp.MustCompile(`\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b`),
	},
	{
		name:    "user_path",
		kind:    "env",
		repType: "user_path",
		re:      userPathRe(),
	},
	{
		name:    "lan_ip",
		kind:    "env",
		repType: "lan_ip",
		re:      regexp.MustCompile(`\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b`),
	},
}

func userPathRe() *regexp.Regexp {
	var homes []string
	if h, err := os.UserHomeDir(); err == nil && len(h) > 1 {
		homes = append(homes, h)
	}
	for _, h := range strings.Split(os.Getenv("ACTIVITY_MESH_REDACT_HOMES"), ":") {
		if h = strings.TrimSpace(h); len(h) > 1 {
			homes = append(homes, h)
		}
	}
	if len(homes) == 0 {
		return regexp.MustCompile(`\bactivity-mesh-no-home-configured\b`)
	}
	quoted := make([]string, len(homes))
	for i, h := range homes {
		quoted[i] = regexp.QuoteMeta(strings.TrimRight(h, "/\\"))
	}
	return regexp.MustCompile(`(?:` + strings.Join(quoted, "|") + `)\b`)
}

var (
	uuidRe   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	hex40Re  = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)
	hex64Re  = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
	ulidRe   = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)
	base64Re = regexp.MustCompile(`[A-Za-z0-9+/=_\-]{32,}`)
)

const minEntropy = 4.5

func Apply(input string) (string, []Hit) {
	if input == "" {
		return input, nil
	}
	out := input
	var hits []Hit

	for _, r := range rules {
		out = r.re.ReplaceAllStringFunc(out, func(match string) string {
			hits = append(hits, mkHit(r.kind, r.name, match))
			return fmt.Sprintf("[REDACTED:%s:%d]", r.repType, len(match))
		})
	}

	out = base64Re.ReplaceAllStringFunc(out, func(match string) string {
		if isAllowlisted(match) {
			return match
		}
		if shannon(match) < minEntropy {
			return match
		}
		hits = append(hits, mkHit("entropy", "high_entropy", match))
		return fmt.Sprintf("[REDACTED:high_entropy:%d]", len(match))
	})

	sort.SliceStable(hits, func(i, j int) bool { return hits[i].PatternName < hits[j].PatternName })
	return out, hits
}

func ApplyJSON(v any) (any, []Hit) {
	var hits []Hit
	out := walk(v, &hits)
	return out, hits
}

func walk(v any, hits *[]Hit) any {
	switch t := v.(type) {
	case string:
		s, h := Apply(t)
		*hits = append(*hits, h...)
		return s
	case map[string]any:
		for k, child := range t {
			t[k] = walk(child, hits)
		}
		return t
	case []any:
		for i, child := range t {
			t[i] = walk(child, hits)
		}
		return t
	default:
		return v
	}
}

func mkHit(kind, pattern, secret string) Hit {
	sum := sha256.Sum256([]byte(secret))
	return Hit{
		Kind:          kind,
		PatternName:   pattern,
		LenRedacted:   len(secret),
		SHA256First12: hex.EncodeToString(sum[:])[:12],
	}
}

func shannon(s string) float64 {
	if s == "" {
		return 0
	}
	freq := make(map[rune]float64, len(s))
	for _, c := range s {
		freq[c]++
	}
	n := float64(len(s))
	var h float64
	for _, c := range freq {
		p := c / n
		h -= p * math.Log2(p)
	}
	return h
}

func isAllowlisted(s string) bool {
	if uuidRe.MatchString(s) {
		return true
	}
	if hex40Re.MatchString(s) {
		return true
	}
	if hex64Re.MatchString(s) {
		return true
	}
	if ulidRe.MatchString(s) {
		return true
	}
	if strings.IndexFunc(s, func(r rune) bool {
		return r >= '0' && r <= '9' || r == '+' || r == '/' || r == '_' || r == '-' || r == '=' || (r >= 'A' && r <= 'Z')
	}) == -1 {
		return true
	}
	return false
}
