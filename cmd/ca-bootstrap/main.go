// Package main is the entry point for ca-bootstrap.
//
// ca-bootstrap takes a fresh laptop to a working ChannelAssist development
// environment. v2.0.0-alpha.1 implements `version` and `doctor` (read-only).
// See docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md for the full spec.
package main

import (
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/cli"
)

// Build-time injected via -ldflags. Default values are "dev" sentinels so
// local `go build` produces something recognisable in bug reports.
var (
	Version   = "dev"
	Commit    = "unknown"
	BuildTime = "unknown"
)

func main() {
	cli.SetBuildInfo(Version, Commit, BuildTime)
	if err := cli.Execute(); err != nil {
		os.Exit(1)
	}
}
