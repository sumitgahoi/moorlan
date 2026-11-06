// Package settings loads host site settings from /etc/moorlan/moorlan.yaml.
// The file holds only static host parameters (not peers or device keys).
package settings

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
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
type Interface struct {
	Name           string
	PublicEndpoint string
	HomeNetworks   []string
	DNSServers     []string
	DNSSearch      []string
}

type file struct {
	PrivateEndpoint string               `yaml:"private-endpoint"`
	Interfaces      map[string]ifaceFile `yaml:"interfaces"`
}

type ifaceFile struct {
	PublicEndpoint string   `yaml:"public-endpoint"`
	HomeNetworks   []string `yaml:"home-networks"`
	DNSServers     []string `yaml:"dns-servers"`
	DNSSearch      []string `yaml:"dns-search"`
}

// Load reads and validates the site YAML. Missing file is an error that names
// the expected path and the shipped example to copy.
func Load() (Site, error) {
	raw, err := os.ReadFile(Path)
	if err != nil {
		if os.IsNotExist(err) {
			return Site{}, fmt.Errorf("site conf %s not found; copy %s and edit it first", Path, ExamplePath)
		}
		return Site{}, err
	}
	var decoded file
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	dec.KnownFields(true)
	if err := dec.Decode(&decoded); err != nil {
		return Site{}, fmt.Errorf("%s: %w", Path, err)
	}
	site := Site{
		PrivateEndpoint: strings.TrimSpace(decoded.PrivateEndpoint),
		Interfaces:      map[string]Interface{},
	}
	if site.PrivateEndpoint == "" {
		return Site{}, fmt.Errorf("%s: private-endpoint is required", Path)
	}
	for name, cfg := range decoded.Interfaces {
		name = strings.TrimSpace(name)
		if name == "" {
			return Site{}, fmt.Errorf("%s: interfaces contains an empty name", Path)
		}
		iface := Interface{
			Name:           name,
			PublicEndpoint: strings.TrimSpace(cfg.PublicEndpoint),
			HomeNetworks:   trimList(cfg.HomeNetworks),
			DNSServers:     trimList(cfg.DNSServers),
			DNSSearch:      trimList(cfg.DNSSearch),
		}
		if iface.PublicEndpoint == "" {
			return Site{}, fmt.Errorf("%s: interfaces.%s.public-endpoint is required", Path, name)
		}
		if len(iface.HomeNetworks) == 0 {
			return Site{}, fmt.Errorf("%s: interfaces.%s.home-networks is required", Path, name)
		}
		if len(iface.DNSServers) == 0 {
			return Site{}, fmt.Errorf("%s: interfaces.%s.dns-servers is required", Path, name)
		}
		site.Interfaces[name] = iface
	}
	return site, nil
}

func trimList(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s != "" {
			out = append(out, s)
		}
	}
	return out
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

// Lookup returns the YAML stanza for name, if present.
func (s Site) Lookup(name string) (Interface, bool) {
	iface, ok := s.Interfaces[name]
	return iface, ok
}
