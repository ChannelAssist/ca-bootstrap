package detect

import "github.com/ChannelAssist/ca-bootstrap/internal/manifest"

// Classification is the result of evaluating a probe Result against a
// tool's manifest entry: OK, drift (required tool missing or below min),
// or missing-optional (optional tool absent or below min).
//
// Extracted here in alpha.3 so doctor (cli), the prereqs wizard step,
// and repair all share one classification rule instead of three copies.
type Classification int

const (
	ClassOK Classification = iota
	ClassDrift
	ClassMissingOptional
)

// Classify evaluates a probe Result against its manifest Tool.
func Classify(t manifest.Tool, r Result) Classification {
	if !r.Found {
		if t.Optional {
			return ClassMissingOptional
		}
		return ClassDrift
	}
	if t.MinVersion != "" {
		ok, err := VersionAtLeast(r.Version, t.MinVersion)
		if err != nil || !ok {
			if t.Optional {
				return ClassMissingOptional
			}
			return ClassDrift
		}
	}
	return ClassOK
}
