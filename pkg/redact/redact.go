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
	// group > 0 redacts only that capture group, leaving the rest of the match
	// in place — used by context rules like `AUTH_TOKEN=<hex>`, where the name
	// is the useful part and only the value is the secret.
	group int
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
		// Open-ended: a capped quantifier redacts the head and leaves the tail of
		// a longer token in plaintext, below the entropy floor.
		name:    "slack_token",
		kind:    "credential",
		repType: "slack_token",
		re:      regexp.MustCompile(`xox[abcerspu]-[A-Za-z0-9-]{10,}`),
	},
	{
		// Bot ids have grown past 10 digits.
		name:    "telegram_bot",
		kind:    "credential",
		repType: "telegram_bot",
		re:      regexp.MustCompile(`\b\d{8,12}:[A-Za-z0-9_\-]{35}\b`),
	},
	{
		name:    "jwt",
		kind:    "credential",
		repType: "jwt",
		re:      regexp.MustCompile(`eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9._+/=\-]+`),
	},
	{
		// Any armoured PRIVATE KEY header, including the trailing " BLOCK" that
		// PGP appends — an enumerated prefix list silently misses new variants.
		name:    "private_key_pem",
		kind:    "credential",
		repType: "private_key",
		re:      regexp.MustCompile(`(?s)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----.+?-----END[^-]+-----`),
	},
	{
		// Any scheme carrying URL userinfo, not just the three DB schemes:
		// redis://, amqp:// and https:// basic-auth leak passwords too. Must stay
		// ahead of the email rule, which otherwise eats the "user:pass@host" tail
		// and leaves the password prefix on disk.
		name:    "db_url",
		kind:    "credential",
		repType: "db_url",
		re:      regexp.MustCompile(`\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+:[^\s/@]+@[^\s/]+`),
	},
	{
		// Hex tops out at 4 bits/char, so a hex-encoded secret can never reach the
		// tier-2 entropy floor. Anchor on the assignment instead: only the value
		// is redacted, the variable name stays readable.
		name:    "hex_secret",
		kind:    "credential",
		repType: "hex_secret",
		re:      regexp.MustCompile(`(?i)[a-z0-9_\-]*(?:secret|token|passwd|password|api[_-]?key|auth|privkey|key)\s*[:=]\s*["']?([0-9a-fA-F]{32,64})\b`),
		group:   1,
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
		if r.group > 0 {
			out = replaceGroup(out, r, &hits)
			continue
		}
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

// replaceGroup redacts only rule.group of every match, keeping the surrounding
// context (the variable name) intact.
func replaceGroup(s string, r *rule, hits *[]Hit) string {
	locs := r.re.FindAllStringSubmatchIndex(s, -1)
	if len(locs) == 0 {
		return s
	}
	var b strings.Builder
	last := 0
	for _, m := range locs {
		lo, hi := m[2*r.group], m[2*r.group+1]
		if lo < 0 || lo < last {
			continue
		}
		secret := s[lo:hi]
		*hits = append(*hits, mkHit(r.kind, r.name, secret))
		b.WriteString(s[last:lo])
		fmt.Fprintf(&b, "[REDACTED:%s:%d]", r.repType, len(secret))
		last = hi
	}
	b.WriteString(s[last:])
	return b.String()
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
		// Keys are caller-controlled on the /push path, so a secret used as a map
		// key would otherwise land on disk verbatim. Build a fresh map: rewriting
		// keys in place during a range can revisit what we just inserted.
		out := make(map[string]any, len(t))
		for k, child := range t {
			cleaned := walk(child, hits)
			key, keyHits := Apply(k)
			if key != k {
				*hits = append(*hits, keyHits...)
			}
			base := key
			for i := 1; ; i++ {
				if _, taken := out[key]; !taken {
					break
				}
				key = fmt.Sprintf("%s#%d", base, i)
			}
			out[key] = cleaned
		}
		return out
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
