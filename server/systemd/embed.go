// Package systemd embeds the host-wide reconcile unit.
package systemd

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"strings"
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

// UnitName is the systemd unit name.
const UnitName = "moorlan-reconcile.service"

// InstallUnit writes the embedded unit if content differs and daemon-reloads.
// It does not enable or start the unit.
func InstallUnit() (changed bool, err error) {
	path := UnitPath()
	want := Render()
	if existing, err := os.ReadFile(path); err == nil && string(existing) == want {
		return false, nil
	}
	if err := os.WriteFile(path, []byte(want), 0o644); err != nil {
		return false, fmt.Errorf("write %s: %w", path, err)
	}
	if err := runSystemctl("daemon-reload"); err != nil {
		return true, err
	}
	return true, nil
}

// Enable enables the unit for boot. It does not start reconcile now.
func Enable() error {
	return runSystemctl("enable", UnitName)
}

func runSystemctl(args ...string) error {
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			return fmt.Errorf("systemctl %s: %w", strings.Join(args, " "), err)
		}
		return fmt.Errorf("systemctl %s: %s", strings.Join(args, " "), msg)
	}
	return nil
}
