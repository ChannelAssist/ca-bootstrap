//go:build windows

package main

import "testing"

// TestEnableConsoleUTF8_NoPanic proves the kernel32!SetConsoleOutputCP
// wiring resolves and is safe to call. It's best-effort (the return value
// is intentionally ignored); running it on windows-latest guards against a
// regression in the lazy-DLL/syscall plumbing that would panic at startup.
func TestEnableConsoleUTF8_NoPanic(t *testing.T) {
	enableConsoleUTF8()
}
