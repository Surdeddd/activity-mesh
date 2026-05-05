//go:build windows

package event

import (
	"os"
	"syscall"
	"unsafe"
)

// On Windows we use LockFileEx for exclusive advisory locking on a region
// covering the whole file. That is sufficient for monotonic_seq increment
// since the file is small (<= 64-bit number serialised as ASCII).

const (
	lockfileExclusiveLock = 0x00000002
)

var (
	modkernel32      = syscall.NewLazyDLL("kernel32.dll")
	procLockFileEx   = modkernel32.NewProc("LockFileEx")
	procUnlockFileEx = modkernel32.NewProc("UnlockFileEx")
)

func flockExclusive(f *os.File) error {
	var ol syscall.Overlapped
	r1, _, e1 := procLockFileEx.Call(
		f.Fd(),
		uintptr(lockfileExclusiveLock),
		0,
		^uintptr(0),
		^uintptr(0),
		uintptr(unsafe.Pointer(&ol)),
	)
	if r1 == 0 {
		return e1
	}
	return nil
}

func flockRelease(f *os.File) error {
	var ol syscall.Overlapped
	r1, _, e1 := procUnlockFileEx.Call(
		f.Fd(),
		0,
		^uintptr(0),
		^uintptr(0),
		uintptr(unsafe.Pointer(&ol)),
	)
	if r1 == 0 {
		return e1
	}
	return nil
}
