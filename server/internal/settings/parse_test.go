package settings

import "testing"

func TestParseOmitsEnabledAndDropsUnknown(t *testing.T) {
	raw := []byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  moorlan0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.83.1]
    legacy-key: ignore-me
`)
	got, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	iface, ok := got.Lookup("moorlan0")
	if !ok {
		t.Fatal("missing iface")
	}
	if iface.Enabled != nil {
		t.Fatal("omitted enabled must be unset (nil)")
	}
	if iface.Name != "Home" || iface.PublicEndpoint != "vpn.example:51820" {
		t.Fatalf("%+v", iface)
	}
}

func TestParseKeepsExplicitEnabled(t *testing.T) {
	raw := []byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    enabled: false
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	got, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	iface := got.Interfaces["wg0"]
	if iface.Enabled == nil || *iface.Enabled {
		t.Fatalf("enabled: %+v", iface.Enabled)
	}
}

func TestParseIgnoresUnknownKey(t *testing.T) {
	raw := []byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    enabled: false
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
    peers: bad
`)
	got, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got.Lookup("wg0"); !ok {
		t.Fatal("missing iface")
	}
}
