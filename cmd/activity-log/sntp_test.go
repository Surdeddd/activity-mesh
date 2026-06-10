package main

import (
	"encoding/binary"
	"testing"
	"time"
)

// cannedResponse builds a valid 48-byte server reply echoing req's transmit
// timestamp, with the given receive (T2) and transmit (T3) server times.
func cannedResponse(t *testing.T, req []byte, t2, t3 time.Time) []byte {
	t.Helper()
	resp := make([]byte, sntpPacketSize)
	resp[0] = 0x24 // LI=0 | VN=4 | Mode=4 (server)
	resp[1] = 2    // stratum 2
	copy(resp[24:32], req[40:48])
	sec, frac := toNTP(t2)
	binary.BigEndian.PutUint32(resp[32:], sec)
	binary.BigEndian.PutUint32(resp[36:], frac)
	sec, frac = toNTP(t3)
	binary.BigEndian.PutUint32(resp[40:], sec)
	binary.BigEndian.PutUint32(resp[44:], frac)
	return resp
}

func TestParseSNTPOffset_KnownOffsets(t *testing.T) {
	base := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name   string
		skew   time.Duration // local − true
		oneWay time.Duration // symmetric network delay
	}{
		{"local 100ms ahead", 100 * time.Millisecond, 10 * time.Millisecond},
		{"local 250ms behind", -250 * time.Millisecond, 5 * time.Millisecond},
		{"in sync", 0, 20 * time.Millisecond},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// True wall-clock at client transmit is base; the skewed local
			// clock reads base+skew at the same instant.
			t1 := base.Add(tc.skew)                  // local
			t2 := base.Add(tc.oneWay)                // server (true)
			t3 := t2.Add(1 * time.Millisecond)       // server processing
			t4 := t1.Add(2*tc.oneWay + time.Millisecond) // local

			req := sntpRequest(t1)
			resp := cannedResponse(t, req, t2, t3)
			got, err := parseSNTPOffset(req, resp, t1, t4)
			if err != nil {
				t.Fatalf("parseSNTPOffset: %v", err)
			}
			// NTP wire format quantizes fractions (~0.23ns); allow 1ms slack.
			if diff := got - tc.skew; diff > time.Millisecond || diff < -time.Millisecond {
				t.Fatalf("offset = %v, want %v (±1ms)", got, tc.skew)
			}
		})
	}
}

func TestParseSNTPOffset_BadPackets(t *testing.T) {
	t1 := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	t4 := t1.Add(20 * time.Millisecond)
	req := sntpRequest(t1)
	good := cannedResponse(t, req, t1, t1)

	mutate := func(f func(resp []byte)) []byte {
		resp := append([]byte(nil), good...)
		f(resp)
		return resp
	}

	cases := []struct {
		name string
		resp []byte
	}{
		{"short packet", good[:20]},
		{"empty packet", nil},
		{"client mode", mutate(func(r []byte) { r[0] = 0x23 })},
		{"kiss of death stratum 0", mutate(func(r []byte) { r[1] = 0 })},
		{"originate mismatch", mutate(func(r []byte) { r[24]++ })},
		{"zero transmit timestamp", mutate(func(r []byte) {
			for i := 40; i < 48; i++ {
				r[i] = 0
			}
		})},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseSNTPOffset(req, tc.resp, t1, t4); err == nil {
				t.Fatal("expected error, got nil")
			}
		})
	}
}

func TestNTPTimestampRoundTrip(t *testing.T) {
	orig := time.Date(2026, 6, 10, 15, 4, 5, 123456789, time.UTC)
	sec, frac := toNTP(orig)
	back := fromNTP(sec, frac)
	if d := back.Sub(orig); d > time.Microsecond || d < -time.Microsecond {
		t.Fatalf("round-trip drift %v (orig %v, back %v)", d, orig, back)
	}
}
