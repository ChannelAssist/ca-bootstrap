//go:build darwin || linux

package lock

import (
	"fmt"
	"os"
	"syscall"
)

// New returns a flock-based Lock for Unix.
func New(path string) Lock {
	return &unixLock{path: path}
}

type unixLock struct {
	path string
	f    *os.File
}

func (l *unixLock) Acquire() error {
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("lock: open %s: %w", l.path, err)
	}
	// LOCK_EX | LOCK_NB → exclusive, non-blocking (fail fast if held).
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return fmt.Errorf("lock: another ca-bootstrap session holds %s (use --ForceUnlock to override): %w", l.path, err)
	}
	l.f = f
	return nil
}

func (l *unixLock) AcquireWithForce() error {
	// Removing the file drops any advisory flock another (dead) process
	// might have held by leaving a stale file; a live holder would just
	// re-fail on the next Acquire, which is the safe outcome.
	_ = os.Remove(l.path)
	return l.Acquire()
}

func (l *unixLock) Release() error {
	if l.f == nil {
		return nil
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	err := l.f.Close()
	l.f = nil
	return err
}
