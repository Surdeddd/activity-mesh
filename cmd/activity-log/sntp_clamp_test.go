package main

import (
	"testing"
	"time"
)

// TestParseSNTPOffset_RejectsImplausibleOffset — a valid-looking reply that
// implies a multi-day skew must be refused, not cached (it would poison every
// event's clock_offset_ms).
func TestParseSNTPOffset_RejectsImplausibleOffset(t *testing.T) {
	base := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	skew := 48 * time.Hour // way past maxSaneOffset
	t1 := base.Add(skew)
	t2 := base.Add(5 * time.Millisecond)
	t3 := t2.Add(time.Millisecond)
	t4 := t1.Add(11 * time.Millisecond)
	req := sntpRequest(t1)
	resp := cannedResponse(t, req, t2, t3)
	if _, err := parseSNTPOffset(req, resp, t1, t4); err == nil {
		t.Fatal("expected implausible-offset rejection")
	}
}

// TestParseSNTPOffset_RejectsNegativeRTT — a reply whose timestamps imply a
// negative round-trip is an unreliable measurement.
func TestParseSNTPOffset_RejectsNegativeRTT(t *testing.T) {
	base := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	t1 := base
	// server "processes" for longer than the whole client round-trip → RTT < 0
	t2 := base.Add(1 * time.Millisecond)
	t3 := t2.Add(100 * time.Millisecond)
	t4 := t1.Add(10 * time.Millisecond)
	req := sntpRequest(t1)
	resp := cannedResponse(t, req, t2, t3)
	if _, err := parseSNTPOffset(req, resp, t1, t4); err == nil {
		t.Fatal("expected negative-RTT rejection")
	}
}
