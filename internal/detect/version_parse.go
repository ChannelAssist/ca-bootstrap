package detect

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// defaultVersionRegex catches `MAJOR.MINOR` or `MAJOR.MINOR.PATCH` —
// matches what most tools print after `--version`. Used when a
// manifest's detect.version_regex is omitted.
const defaultVersionRegex = `(\d+\.\d+(?:\.\d+)?)`

// ExtractVersion finds the first version-like substring in raw output.
// If pattern is "" it uses defaultVersionRegex.
// Returns "" if the regex doesn't compile or doesn't match — never
// returns an error (callers treat empty version as "not parseable").
func ExtractVersion(raw, pattern string) string {
	if pattern == "" {
		pattern = defaultVersionRegex
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return ""
	}
	match := re.FindStringSubmatch(raw)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

// VersionAtLeast reports whether got >= min using semver-style compare.
// Both 2-part (1.21) and 3-part (1.21.5) versions are accepted on each
// side; missing parts are treated as 0. Empty min is "any version".
// Prerelease/build metadata after `-` or `+` is ignored for comparison.
func VersionAtLeast(got, min string) (bool, error) {
	if min == "" {
		return true, nil
	}
	g, err := parseTriplet(got)
	if err != nil {
		return false, fmt.Errorf("parse got %q: %w", got, err)
	}
	m, err := parseTriplet(min)
	if err != nil {
		return false, fmt.Errorf("parse min %q: %w", min, err)
	}
	for i := 0; i < 3; i++ {
		if g[i] != m[i] {
			return g[i] > m[i], nil
		}
	}
	return true, nil
}

// parseTriplet parses MAJOR[.MINOR[.PATCH]] into a [3]int, treating
// missing parts as 0. Strips any prerelease/build metadata.
func parseTriplet(s string) ([3]int, error) {
	if i := strings.IndexAny(s, "-+"); i >= 0 {
		s = s[:i]
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return [3]int{}, fmt.Errorf("too many parts: %q", s)
	}
	var out [3]int
	for i, p := range parts {
		v, err := strconv.Atoi(p)
		if err != nil {
			return [3]int{}, fmt.Errorf("non-numeric component %q: %w", p, err)
		}
		out[i] = v
	}
	return out, nil
}
