package settings

import (
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// Parse decodes YAML into a Site. Unknown keys are ignored. Omitted keys stay
// unset (Enabled nil, empty strings/lists). Does not validate.
func Parse(raw []byte) (Site, error) {
	var decoded file
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	dec.KnownFields(false)
	if err := dec.Decode(&decoded); err != nil {
		return Site{}, fmt.Errorf("%s: %w", Path, err)
	}
	site := Site{
		PrivateEndpoint: strings.TrimSpace(decoded.PrivateEndpoint),
		Interfaces:      map[string]Interface{},
	}
	if decoded.Interfaces == nil {
		return site, nil
	}
	for name, cfg := range decoded.Interfaces {
		name = strings.TrimSpace(name)
		if name == "" {
			return Site{}, fmt.Errorf("%s: interfaces contains an empty name", Path)
		}
		site.Interfaces[name] = Interface{
			Enabled:        cfg.Enabled,
			Name:           strings.TrimSpace(cfg.Name),
			PublicEndpoint: strings.TrimSpace(cfg.PublicEndpoint),
			HomeNetworks:   trimList(cfg.HomeNetworks),
			DNSServers:     trimList(cfg.DNSServers),
			DNSSearch:      trimList(cfg.DNSSearch),
		}
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
