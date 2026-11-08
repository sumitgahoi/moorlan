// Package setup implements moorlan --setup: YAML merge, DB migrate, unit enable.
package setup

import (
	"fmt"
	"io"
	"os"

	"moorlan/internal/runtime"
	"moorlan/internal/settings"
	"moorlan/systemd"
)

// Options control --setup. Tests override Stun and writers.
type Options struct {
	Stun   StunFunc
	Stdout io.Writer
	Stderr io.Writer
}

// Run follows the install sequence after the binary is already on disk:
// merge YAML → migrate DB → replace systemd unit → enable for boot → messages.
// It does not run reconcile; that happens on boot or via --pair / --reconcile.
func Run(opts Options) error {
	stdout := opts.Stdout
	if stdout == nil {
		stdout = os.Stdout
	}
	stderr := opts.Stderr
	if stderr == nil {
		stderr = os.Stderr
	}

	// 1. Discover + create/merge site YAML
	guessed, notes, err := Discover(opts.Stun)
	if err != nil {
		return fmt.Errorf("discover: %w", err)
	}
	for _, note := range notes {
		fmt.Fprintf(stderr, "moorlan: %s\n", note)
	}

	var merged settings.Site
	if !settings.Exists() {
		merged = guessed
		fmt.Fprintf(stderr, "moorlan: creating %s\n", settings.Path)
	} else {
		existing, err := settings.Load()
		if err != nil {
			return fmt.Errorf("load existing conf: %w", err)
		}
		var mergeNotes []string
		merged, mergeNotes = settings.Merge(existing, guessed)
		for _, note := range mergeNotes {
			fmt.Fprintf(stderr, "moorlan: %s\n", note)
		}
		fmt.Fprintf(stderr, "moorlan: merged into %s\n", settings.Path)
	}
	if err := settings.Validate(merged); err != nil {
		return fmt.Errorf("validate merged conf: %w", err)
	}
	if err := settings.Write(merged); err != nil {
		return err
	}

	// 2. Upgrade DB if needed
	if err := runtime.MigrateStore(runtime.DefaultStorePath); err != nil {
		return fmt.Errorf("migrate database: %w", err)
	}
	fmt.Fprintf(stderr, "moorlan: database ready at %s\n", runtime.DefaultStorePath)

	// 3. Replace systemd unit
	changed, err := systemd.InstallUnit()
	if err != nil {
		return fmt.Errorf("install systemd unit: %w", err)
	}
	if changed {
		fmt.Fprintf(stderr, "moorlan: installed %s\n", systemd.UnitPath())
	} else {
		fmt.Fprintf(stderr, "moorlan: systemd unit up to date\n")
	}

	// 4. Enable for boot only (no reconcile now)
	if err := systemd.Enable(); err != nil {
		return fmt.Errorf("enable systemd unit: %w", err)
	}
	fmt.Fprintf(stderr, "moorlan: reconcile unit enabled for boot\n")

	// 5. Post-install messages
	printSummary(stdout, merged)
	fmt.Fprintf(stderr, "\nReview %s (set enabled: true on interfaces to manage),\nthen: sudo moorlan --pair\n", settings.Path)
	return nil
}

func printSummary(w io.Writer, site settings.Site) {
	fmt.Fprintf(w, "private-endpoint: %s\n", site.PrivateEndpoint)
	if len(site.Interfaces) == 0 {
		fmt.Fprintf(w, "interfaces: (none discovered — bring up a WireGuard device and re-run --setup)\n")
		return
	}
	for _, name := range site.InterfaceNames() {
		cfg := site.Interfaces[name]
		fmt.Fprintf(w, "interfaces.%s:\n", name)
		enabled := false
		if cfg.Enabled != nil {
			enabled = *cfg.Enabled
		}
		fmt.Fprintf(w, "  enabled: %v\n", enabled)
		fmt.Fprintf(w, "  name: %s\n", cfg.Name)
		fmt.Fprintf(w, "  public-endpoint: %s\n", cfg.PublicEndpoint)
		fmt.Fprintf(w, "  home-networks: %v\n", cfg.HomeNetworks)
		fmt.Fprintf(w, "  dns-servers: %v\n", cfg.DNSServers)
		fmt.Fprintf(w, "  dns-search: %v\n", cfg.DNSSearch)
	}
}
