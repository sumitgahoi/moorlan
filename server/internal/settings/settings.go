// Package settings loads and writes host site settings from /etc/moorlan/moorlan.yaml.
// The file holds only static host parameters (not peers or device keys).
//
// Pipeline: Parse/Load → (Merge with CreateDefaultConf) → Validate → Write.
package settings

import (
	"os"
	"sort"
)

// Path is the canonical site conf path. Tests may override it.
var Path = "/etc/moorlan/moorlan.yaml"

// ExamplePath is where the packaged example YAML is installed.
const ExamplePath = "/usr/share/moorlan/moorlan.yaml.example"

// Site is the static host configuration.
type Site struct {
	PrivateEndpoint string
	Interfaces      map[string]Interface
}

// Interface is static settings for one WireGuard interface.
// Name is the tunnel display name from YAML `name` (not the map key, which is
// the WireGuard interface name).
//
// Enabled is a pointer only so parse/merge can tell omit from an explicit
// bool. Runtime treats solely enabled: true as on; nil, false, and missing
// from YAML are all off.
type Interface struct {
	Enabled        *bool
	Name           string
	PublicEndpoint string
	HomeNetworks   []string
	DNSServers     []string
	DNSSearch      []string
}

// file is the on-disk YAML shape (known keys only on encode).
type file struct {
	PrivateEndpoint string               `yaml:"private-endpoint"`
	Interfaces      map[string]ifaceFile `yaml:"interfaces"`
}

type ifaceFile struct {
	Enabled        *bool    `yaml:"enabled"`
	Name           string   `yaml:"name"`
	PublicEndpoint string   `yaml:"public-endpoint"`
	HomeNetworks   []string `yaml:"home-networks"`
	DNSServers     []string `yaml:"dns-servers"`
	DNSSearch      []string `yaml:"dns-search"`
}

// Exists reports whether the site conf file is present.
func Exists() bool {
	_, err := os.Stat(Path)
	return err == nil
}

// InterfaceNames returns configured interface names in stable order.
func (s Site) InterfaceNames() []string {
	names := make([]string, 0, len(s.Interfaces))
	for name := range s.Interfaces {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// InterfaceEnabled reports whether name is listed with enabled: true.
// Missing, enabled: false, and omitted enabled are all false.
func (s Site) InterfaceEnabled(name string) bool {
	iface, ok := s.Lookup(name)
	return ok && iface.Enabled != nil && *iface.Enabled
}

// EnabledInterfaceNames returns names with enabled: true in stable order.
func (s Site) EnabledInterfaceNames() []string {
	var names []string
	for _, name := range s.InterfaceNames() {
		if s.InterfaceEnabled(name) {
			names = append(names, name)
		}
	}
	return names
}

// DisabledInterfaceNames returns listed names that are not enabled: true
// (false or omitted) in stable order.
func (s Site) DisabledInterfaceNames() []string {
	var names []string
	for _, name := range s.InterfaceNames() {
		if !s.InterfaceEnabled(name) {
			names = append(names, name)
		}
	}
	return names
}

// Lookup returns the YAML stanza for name, if present.
func (s Site) Lookup(name string) (Interface, bool) {
	iface, ok := s.Interfaces[name]
	return iface, ok
}

func boolPtr(v bool) *bool {
	b := v
	return &b
}
