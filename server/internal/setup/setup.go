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
	Stderr io.Writer
}

// Run follows the install sequence after the binary is already on disk:
// merge YAML → migrate DB → replace systemd unit → enable for boot → messages.
// It does not run reconcile; that happens on boot or via --pair / --reconcile.
func Run(opts Options) error {
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

	// 5. Next step (do not dump YAML — operator reviews the file)
	if len(merged.Interfaces) == 0 {
		fmt.Fprintf(stderr, "\nNo WireGuard interfaces discovered. Bring one up, then: sudo moorlan --setup\n")
		return nil
	}
	fmt.Fprintf(stderr, "\nReview %s (set enabled: true on interfaces to manage),\nthen: sudo moorlan --pair\n", settings.Path)
	return nil
}
