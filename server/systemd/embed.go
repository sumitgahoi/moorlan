// Package systemd embeds the host-wide reconcile unit.
package systemd

import (
	_ "embed"
)

//go:embed moorlan-reconcile.service
var unit string

// Render returns the host-wide moorlan-reconcile.service contents.
func Render() string {
	return unit
}

// UnitPath is where the installed unit lives.
func UnitPath() string {
	return "/etc/systemd/system/moorlan-reconcile.service"
}
