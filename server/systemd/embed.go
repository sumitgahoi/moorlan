// Package systemd embeds and renders the rehydrate unit template.
package systemd

import (
	_ "embed"
	"fmt"
	"strings"
)

//go:embed moorlan-rehydrate.service
var template string

const ifacePlaceholder = "__IFACE__"

// Render returns a rehydrate unit with __IFACE__ replaced by iface.
func Render(iface string) (string, error) {
	if iface == "" {
		return "", fmt.Errorf("interface name required")
	}
	if strings.Contains(iface, ifacePlaceholder) {
		return "", fmt.Errorf("invalid interface name")
	}
	return strings.ReplaceAll(template, ifacePlaceholder, iface), nil
}

// UnitPath is where an installed unit should live.
func UnitPath(iface string) string {
	return "/etc/systemd/system/moorlan-rehydrate-" + iface + ".service"
}
