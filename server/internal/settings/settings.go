// Package settings loads and writes host site settings from /etc/moorlan/moorlan.yaml.
// The file holds only static host parameters (not peers or device keys).
package settings

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"moorlan/internal/payload"

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
// Name is the tunnel display name from YAML `name` (not the map key, which is
// the WireGuard interface name).
type Interface struct {
	Enabled        bool
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
	Enabled        *bool    `yaml:"enabled"`
	Name           string   `yaml:"name"`
	PublicEndpoint string   `yaml:"public-endpoint"`
	HomeNetworks   []string `yaml:"home-networks"`
	DNSServers     []string `yaml:"dns-servers"`
	DNSSearch      []string `yaml:"dns-search"`
}

// Load reads and validates the site YAML. Missing file is an error that names
// the expected path and suggests --setup.
func Load() (Site, error) {
	raw, err := os.ReadFile(Path)
	if err != nil {
		if os.IsNotExist(err) {
			return Site{}, fmt.Errorf("site conf %s not found; run: sudo moorlan --setup (or re-run install.sh); example: %s", Path, ExamplePath)
		}
		return Site{}, err
	}
	return parse(raw)
}

// Exists reports whether the site conf file is present.
func Exists() bool {
	_, err := os.Stat(Path)
	return err == nil
}

func parse(raw []byte) (Site, error) {
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
		if cfg.Enabled == nil {
			return Site{}, fmt.Errorf("%s: interfaces.%s.enabled is required", Path, name)
		}
		iface := Interface{
			Enabled:        *cfg.Enabled,
			Name:           strings.TrimSpace(cfg.Name),
			PublicEndpoint: strings.TrimSpace(cfg.PublicEndpoint),
			HomeNetworks:   trimList(cfg.HomeNetworks),
			DNSServers:     trimList(cfg.DNSServers),
			DNSSearch:      trimList(cfg.DNSSearch),
		}
		if err := payload.ValidateName(iface.Name); err != nil {
			return Site{}, fmt.Errorf("%s: interfaces.%s.name: %w", Path, name, err)
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

// EnabledInterfaceNames returns names with enabled: true in stable order.
func (s Site) EnabledInterfaceNames() []string {
	var names []string
	for _, name := range s.InterfaceNames() {
		if s.Interfaces[name].Enabled {
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

// Merge combines guessed defaults with an existing site. Existing non-empty
// strings/lists and existing enabled values win. New guessed ifaces are added.
// Stanzas only in existing are kept.
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
	out.Enabled = existing.Enabled
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

// Write atomically writes site conf to Path.
func Write(site Site) error {
	if err := os.MkdirAll(filepath.Dir(Path), 0o755); err != nil {
		return err
	}
	body, err := Encode(site)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(Path), "moorlan.yaml.*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, Path); err != nil {
		return err
	}
	ok = true
	return nil
}

// Encode marshals site conf to YAML bytes.
func Encode(site Site) ([]byte, error) {
	decoded := file{
		PrivateEndpoint: site.PrivateEndpoint,
		Interfaces:      map[string]ifaceFile{},
	}
	for _, name := range site.InterfaceNames() {
		cfg := site.Interfaces[name]
		en := cfg.Enabled
		decoded.Interfaces[name] = ifaceFile{
			Enabled:        &en,
			Name:           cfg.Name,
			PublicEndpoint: cfg.PublicEndpoint,
			HomeNetworks:   append([]string(nil), cfg.HomeNetworks...),
			DNSServers:     append([]string(nil), cfg.DNSServers...),
			DNSSearch:      append([]string(nil), cfg.DNSSearch...),
		}
	}
	var buf strings.Builder
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(decoded); err != nil {
		return nil, err
	}
	_ = enc.Close()
	return []byte(buf.String()), nil
}
