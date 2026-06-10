// Minimal pure-Go SNTP (RFC 4330) client for `activity-log clock-sync`.
// One UDP round-trip, no external deps, no exec. Good to ±a few ms, which is
// plenty for ordering cross-host JSONL events.
package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"time"
)

const (
	sntpPacketSize = 48
	// Seconds between the NTP epoch (1900-01-01) and the Unix epoch (1970-01-01).
	ntpUnixDelta = 2208988800
)

// toNTP converts a time.Time to NTP wire format (seconds, fraction).
func toNTP(t time.Time) (sec, frac uint32) {
	secs := uint64(t.Unix()) + ntpUnixDelta
	sec = uint32(secs)
	frac = uint32(uint64(t.Nanosecond()) << 32 / 1e9)
	return
}

// fromNTP converts NTP wire format back to a time.Time (UTC).
// Valid until the 2036 era rollover, like every era-0 SNTP client.
func fromNTP(sec, frac uint32) time.Time {
	unix := int64(sec) - ntpUnixDelta
	nsec := int64(uint64(frac) * 1e9 >> 32)
	return time.Unix(unix, nsec).UTC()
}

// sntpRequest builds a 48-byte client request. LI=0, VN=4, Mode=3 (client).
// The transmit timestamp (bytes 40..47) carries t1 so the server echoes it
// back in the originate field — our anti-spoof / stale-reply check.
func sntpRequest(t1 time.Time) []byte {
	req := make([]byte, sntpPacketSize)
	req[0] = 0x23 // LI=0 | VN=4 | Mode=3
	sec, frac := toNTP(t1)
	binary.BigEndian.PutUint32(req[40:], sec)
	binary.BigEndian.PutUint32(req[44:], frac)
	return req
}

// parseSNTPOffset validates a server reply against the request and computes
// the local clock offset as local−true: ((T1−T2)+(T4−T3))/2.
// Positive = local clock runs ahead of true time.
//
//	T1 = client transmit, T2 = server receive,
//	T3 = server transmit, T4 = client receive.
func parseSNTPOffset(req, resp []byte, t1, t4 time.Time) (time.Duration, error) {
	if len(resp) < sntpPacketSize {
		return 0, fmt.Errorf("short packet: %d bytes (want %d)", len(resp), sntpPacketSize)
	}
	if mode := resp[0] & 0x07; mode != 4 && mode != 5 {
		return 0, fmt.Errorf("not a server reply (mode %d)", mode)
	}
	if stratum := resp[1]; stratum == 0 {
		return 0, fmt.Errorf("kiss-of-death reply (stratum 0)")
	}
	// Originate timestamp must echo our transmit timestamp.
	if string(resp[24:32]) != string(req[40:48]) {
		return 0, fmt.Errorf("originate timestamp mismatch (stale or spoofed reply)")
	}
	t2 := fromNTP(binary.BigEndian.Uint32(resp[32:]), binary.BigEndian.Uint32(resp[36:]))
	t3 := fromNTP(binary.BigEndian.Uint32(resp[40:]), binary.BigEndian.Uint32(resp[44:]))
	if t3.IsZero() || binary.BigEndian.Uint32(resp[40:]) == 0 {
		return 0, fmt.Errorf("server transmit timestamp unset")
	}
	return (t1.Sub(t2) + t4.Sub(t3)) / 2, nil
}

// measureClockOffset performs one SNTP round-trip against server (host:port)
// within timeout and returns the local clock offset.
func measureClockOffset(server string, timeout time.Duration) (time.Duration, error) {
	conn, err := net.DialTimeout("udp", server, timeout)
	if err != nil {
		return 0, fmt.Errorf("dial %s: %w", server, err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, err
	}
	t1 := time.Now()
	req := sntpRequest(t1)
	if _, err := conn.Write(req); err != nil {
		return 0, fmt.Errorf("send to %s: %w", server, err)
	}
	resp := make([]byte, sntpPacketSize)
	n, err := conn.Read(resp)
	t4 := time.Now()
	if err != nil {
		return 0, fmt.Errorf("read from %s: %w", server, err)
	}
	return parseSNTPOffset(req, resp[:n], t1, t4)
}
