package settings

// DefaultIface is one WireGuard interface for CreateDefaultConf.
// Caller supplies every field; CreateDefaultConf sets enabled: false explicitly.
type DefaultIface struct {
	Name           string
	PublicEndpoint string
	HomeNetworks   []string
	DNSServers     []string
	DNSSearch      []string
}

// CreateDefaultConf builds a fully-keyed guessed Site (no I/O). Every interface
// gets enabled: false set explicitly; string/list fields are copied as given.
func CreateDefaultConf(privateEndpoint string, ifaces map[string]DefaultIface) Site {
	site := Site{
		PrivateEndpoint: privateEndpoint,
		Interfaces:      map[string]Interface{},
	}
	for device, in := range ifaces {
		site.Interfaces[device] = Interface{
			Enabled:        boolPtr(false),
			Name:           in.Name,
			PublicEndpoint: in.PublicEndpoint,
			HomeNetworks:   append([]string(nil), in.HomeNetworks...),
			DNSServers:     append([]string(nil), in.DNSServers...),
			DNSSearch:      append([]string(nil), in.DNSSearch...),
		}
	}
	return site
}
