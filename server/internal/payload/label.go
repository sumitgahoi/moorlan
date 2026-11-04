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
	label = strings.TrimSpace(label)
	if label == "" {
		return fmt.Errorf("device label is required")
	}
	if !utf8.ValidString(label) {
		return fmt.Errorf("device label is not valid UTF-8")
	}
	if utf8.RuneCountInString(label) > maxLabelRunes {
		return fmt.Errorf("device label is too long")
	}
	for _, r := range label {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("device label contains control characters")
		}
	}
	return nil
}

// NormalizeLabel trims a validated label.
func NormalizeLabel(label string) string {
	return strings.TrimSpace(label)
}
