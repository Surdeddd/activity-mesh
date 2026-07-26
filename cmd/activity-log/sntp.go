package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"time"
)

const (
	sntpPacketSize = 48
	ntpUnixDelta   = 2208988800
	maxSaneOffset  = 24 * time.Hour
	maxSaneRTT     = 10 * time.Second
)

func toNTP(t time.Time) (sec, frac uint32) {
	secs := uint64(t.Unix()) + ntpUnixDelta
	sec = uint32(secs)
	frac = uint32(uint64(t.Nanosecond()) << 32 / 1e9)
	return
}

func fromNTP(sec, frac uint32) time.Time {
	unix := int64(sec) - ntpUnixDelta
	nsec := int64(uint64(frac) * 1e9 >> 32)
	return time.Unix(unix, nsec).UTC()
}

func sntpRequest(t1 time.Time) []byte {
	req := make([]byte, sntpPacketSize)
	req[0] = 0x23 // LI=0 | VN=4 | Mode=3
	sec, frac := toNTP(t1)
	binary.BigEndian.PutUint32(req[40:], sec)
	binary.BigEndian.PutUint32(req[44:], frac)
	return req
}

func parseSNTPOffset(req, resp []byte, t1, t4 time.Time) (time.Duration, error) {
	if len(resp) < sntpPacketSize {
		return 0, fmt.Errorf("short packet: %d bytes (want %d)", len(resp), sntpPacketSize)
	}
	if mode := resp[0] & 0x07; mode != 4 && mode != 5 {
		return 0, fmt.Errorf("not a server reply (mode %d)", mode)
	}
	// A server that says it is itself unsynchronised must not be trusted: its
	// offset would be cached and stamped onto every event this host emits.
	if li := resp[0] >> 6; li == 3 {
		return 0, fmt.Errorf("server clock unsynchronised (LI=3)")
	}
	if stratum := resp[1]; stratum == 0 {
		return 0, fmt.Errorf("kiss-of-death reply (stratum 0)")
	} else if stratum >= 16 {
		return 0, fmt.Errorf("server unsynchronised (stratum %d)", stratum)
	}
	if string(resp[24:32]) != string(req[40:48]) {
		return 0, fmt.Errorf("originate timestamp mismatch (stale or spoofed reply)")
	}
	t2 := fromNTP(binary.BigEndian.Uint32(resp[32:]), binary.BigEndian.Uint32(resp[36:]))
	t3 := fromNTP(binary.BigEndian.Uint32(resp[40:]), binary.BigEndian.Uint32(resp[44:]))
	if t3.IsZero() || binary.BigEndian.Uint32(resp[40:]) == 0 {
		return 0, fmt.Errorf("server transmit timestamp unset")
	}
	rtt := t4.Sub(t1) - t3.Sub(t2)
	if rtt < 0 || rtt > maxSaneRTT {
		return 0, fmt.Errorf("implausible round-trip %v — measurement unreliable", rtt)
	}
	offset := (t1.Sub(t2) + t4.Sub(t3)) / 2
	if offset < -maxSaneOffset || offset > maxSaneOffset {
		return 0, fmt.Errorf("implausible offset %v — refusing to cache", offset)
	}
	return offset, nil
}

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
