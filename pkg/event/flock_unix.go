//go:build !windows

package event

import (
	"os"
	"syscall"
)

// flockExclusive grabs an exclusive advisory lock on f. Blocks until acquired.
func flockExclusive(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
}

// flockRelease releases the advisory lock.
func flockRelease(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}
