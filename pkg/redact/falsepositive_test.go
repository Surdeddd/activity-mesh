package redact

import (
	"strings"
	"testing"
)

func TestNoFalsePositiveProse(t *testing.T) {
	cases := []string{
		"risk-assessment-2026-priority-list updated",   // old sk- rule matched mid-word
		"disk-cleanup-and-defragmentation-notes ready", // same class
		"macOS version 10.15.7 installed",              // old 3-octet 10.x rule
		"see release 10.14.6 changelog",
		"kiosk-mode-configuration-details saved",
	}
	for _, in := range cases {
		got, hits := Apply(in)
		if got != in {
			t.Errorf("false positive: %q -> %q (hits=%+v)", in, got, hits)
		}
	}
}

func TestLanIPFourOctets(t *testing.T) {
	got, _ := Apply("db lives at 10.0.0.17 now")
	if strings.Contains(got, "10.0.0.17") || strings.Contains(got, ".17") {
		t.Errorf("lan ip leaked: %q", got)
	}
	if !strings.Contains(got, "[REDACTED:lan_ip:") {
		t.Errorf("lan ip not redacted: %q", got)
	}
}

func TestModernCredentialPatterns(t *testing.T) {
	cases := []struct{ name, in, marker string }{
		{"github_oauth", "token gho_" + strings.Repeat("A", 36), "github_token"},
		{"github_refresh", "token ghr_" + strings.Repeat("B", 36), "github_token"},
		{"gitlab_pat", "glpat-" + strings.Repeat("x", 22), "gitlab_token"},
		{"google_api", "key AIza" + strings.Repeat("D", 35), "google_api_key"},
		{"stripe_live", "sk_live_" + strings.Repeat("e", 26), "stripe_key"},
		{"stripe_restricted", "rk_test_" + strings.Repeat("f", 26), "stripe_key"},
		{"huggingface", "hf_" + strings.Repeat("G", 34), "huggingface_token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, hits := Apply(tc.in)
			if strings.Contains(got, tc.in[strings.LastIndex(tc.in, " ")+1:]) {
				t.Fatalf("credential survived: %q -> %q", tc.in, got)
			}
			found := false
			for _, h := range hits {
				if h.PatternName == tc.marker {
					found = true
				}
			}
			if !found {
				t.Errorf("expected hit %q, got %+v", tc.marker, hits)
			}
		})
	}
}

func TestCurrentHomeRedacted(t *testing.T) {
	home := mustHome(t)
	got, _ := Apply("wrote to " + home + "/some/file.txt")
	if strings.Contains(got, home) {
		t.Errorf("home dir leaked: %q", got)
	}
}
