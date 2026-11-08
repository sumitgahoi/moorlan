package settings

import (
	"fmt"
	"strings"
)

// Merge combines an existing site (from Load/Parse) with a guessed site
// (from CreateDefaultConf). Start from guessed; overlay set fields from
// existing. Unset existing fields keep the guess.
func Merge(existing, guessed Site) (Site, []string) {
	var notes []string
	out := Site{
		PrivateEndpoint: guessed.PrivateEndpoint,
		Interfaces:      map[string]Interface{},
	}
	if strings.TrimSpace(existing.PrivateEndpoint) != "" {
		out.PrivateEndpoint = existing.PrivateEndpoint
	}
	seen := map[string]bool{}
	for _, name := range existing.InterfaceNames() {
		seen[name] = true
		ex := existing.Interfaces[name]
		if g, ok := guessed.Interfaces[name]; ok {
			out.Interfaces[name] = mergeIface(ex, g)
			continue
		}
		out.Interfaces[name] = ex
		notes = append(notes, fmt.Sprintf("kept %s in conf (not seen on host)", name))
	}
	for _, name := range guessed.InterfaceNames() {
		if seen[name] {
			continue
		}
		out.Interfaces[name] = guessed.Interfaces[name]
		notes = append(notes, fmt.Sprintf("added %s (enabled: false)", name))
	}
	return out, notes
}

func mergeIface(existing, guessed Interface) Interface {
	out := guessed
	if existing.Enabled != nil {
		out.Enabled = existing.Enabled
	}
	if strings.TrimSpace(existing.Name) != "" {
		out.Name = existing.Name
	}
	if strings.TrimSpace(existing.PublicEndpoint) != "" {
		out.PublicEndpoint = existing.PublicEndpoint
	}
	if len(existing.HomeNetworks) > 0 {
		out.HomeNetworks = append([]string(nil), existing.HomeNetworks...)
	}
	if len(existing.DNSServers) > 0 {
		out.DNSServers = append([]string(nil), existing.DNSServers...)
	}
	if len(existing.DNSSearch) > 0 {
		out.DNSSearch = append([]string(nil), existing.DNSSearch...)
	}
	return out
}
