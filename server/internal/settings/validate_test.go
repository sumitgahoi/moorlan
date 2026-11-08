package settings

import (
	"strings"
	"testing"
)

func TestValidateRequiresEnabled(t *testing.T) {
	site, err := Parse([]byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`))
	if err != nil {
		t.Fatal(err)
	}
	err = Validate(site)
	if err == nil || !strings.Contains(err.Error(), "enabled") {
		t.Fatalf("missing enabled: %v", err)
	}
}

func TestValidateAcceptsFullSite(t *testing.T) {
	site := CreateDefaultConf("10.10.10.1:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Home", PublicEndpoint: "vpn.example:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.10.10.1"},
			DNSSearch:    []string{"home.arpa"},
		},
	})
	if err := Validate(site); err != nil {
		t.Fatal(err)
	}
}

func TestValidateRequiresPrivateEndpoint(t *testing.T) {
	site := CreateDefaultConf("", map[string]DefaultIface{
		"wg0": {
			Name: "Home", PublicEndpoint: "vpn.example:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.10.10.1"},
		},
	})
	err := Validate(site)
	if err == nil || !strings.Contains(err.Error(), "private-endpoint") {
		t.Fatalf("%v", err)
	}
}
