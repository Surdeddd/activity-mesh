//go:build windows

package event

import (
	"os"
	"syscall"
	"unsafe"
)

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
