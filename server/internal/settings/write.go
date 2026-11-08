package settings

import (
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Write validates then atomically writes site conf to Path.
func Write(site Site) error {
	if err := Validate(site); err != nil {
		return err
	}
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

// Encode marshals site conf to YAML bytes (known keys only).
func Encode(site Site) ([]byte, error) {
	decoded := file{
		PrivateEndpoint: site.PrivateEndpoint,
		Interfaces:      map[string]ifaceFile{},
	}
	for _, name := range site.InterfaceNames() {
		cfg := site.Interfaces[name]
		decoded.Interfaces[name] = ifaceFile{
			Enabled:        cfg.Enabled,
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
