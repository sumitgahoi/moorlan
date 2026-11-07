package payload

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

const maxLabelRunes = 64

// ValidateLabel accepts a short admin-visible device name for SQLite and conf comments.
// Labels need not be unique; admin removal prefers the WireGuard public key.
func ValidateLabel(label string) error {
	return validateShortName("device label", label)
}

// ValidateName accepts the tunnel display name from site conf / lease.
func ValidateName(name string) error {
	return validateShortName("name", name)
}

func validateShortName(what, value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("%s is required", what)
	}
	if !utf8.ValidString(value) {
		return fmt.Errorf("%s is not valid UTF-8", what)
	}
	if utf8.RuneCountInString(value) > maxLabelRunes {
		return fmt.Errorf("%s is too long", what)
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("%s contains control characters", what)
		}
	}
	return nil
}

// NormalizeLabel trims a validated label.
func NormalizeLabel(label string) string {
	return strings.TrimSpace(label)
}
