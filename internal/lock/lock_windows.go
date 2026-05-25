//go:build windows

package lock

import (
	"fmt"
	"os"

	"golang.org/x/sys/windows"
)

// New returns a LockFileEx-based Lock for Windows.
func New(path string) Lock {
	return &windowsLock{path: path}
}

type windowsLock struct {
	path string
	f    *os.File
}

func (l *windowsLock) Acquire() error {
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("lock: open %s: %w", l.path, err)
	}
	h := windows.Handle(f.Fd())
	var ol windows.Overlapped
	// EXCLUSIVE | FAIL_IMMEDIATELY → fail fast if another process holds it.
	err = windows.LockFileEx(h,
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, 1, 0, &ol)
	if err != nil {
		_ = f.Close()
		return fmt.Errorf("lock: another ca-bootstrap session holds %s (use --ForceUnlock to override): %w", l.path, err)
	}
	l.f = f
	return nil
}

func (l *windowsLock) AcquireWithForce() error {
	_ = os.Remove(l.path)
	return l.Acquire()
}

func (l *windowsLock) Release() error {
	if l.f == nil {
		return nil
	}
	h := windows.Handle(l.f.Fd())
	var ol windows.Overlapped
	_ = windows.UnlockFileEx(h, 0, 1, 0, &ol)
	err := l.f.Close()
	l.f = nil
	return err
}
