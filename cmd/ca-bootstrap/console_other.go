//go:build !windows

package main

// enableConsoleUTF8 is a no-op on non-Windows platforms — their
// terminals are UTF-8 by default.
func enableConsoleUTF8() {}
