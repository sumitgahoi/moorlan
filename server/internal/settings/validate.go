package settings

import (
	"fmt"
	"strings"

	"moorlan/internal/payload"
)

// Validate requires every site key to be explicitly set: non-empty
// private-endpoint; per iface enabled non-nil, valid name, non-empty
// public-endpoint / home-networks / dns-servers.
func Validate(site Site) error {
	if strings.TrimSpace(site.PrivateEndpoint) == "" {
		return fmt.Errorf("%s: private-endpoint is required", Path)
	}
	for _, name := range site.InterfaceNames() {
		iface := site.Interfaces[name]
		if iface.Enabled == nil {
			return fmt.Errorf("%s: interfaces.%s.enabled is required", Path, name)
		}
		if err := payload.ValidateName(iface.Name); err != nil {
			return fmt.Errorf("%s: interfaces.%s.name: %w", Path, name, err)
		}
		if iface.PublicEndpoint == "" {
			return fmt.Errorf("%s: interfaces.%s.public-endpoint is required", Path, name)
		}
		if len(iface.HomeNetworks) == 0 {
			return fmt.Errorf("%s: interfaces.%s.home-networks is required", Path, name)
		}
		if len(iface.DNSServers) == 0 {
			return fmt.Errorf("%s: interfaces.%s.dns-servers is required", Path, name)
		}
	}
	return nil
}
