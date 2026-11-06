package settings

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeSite(t *testing.T, raw string) {
	t.Helper()
	Path = filepath.Join(t.TempDir(), "moorlan.yaml")
	if err := os.WriteFile(Path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoadRoundTripKeys(t *testing.T) {
	writeSite(t, `
db: /var/lib/moorlan/moorlan.db
private-endpoint: 10.10.10.1:8756
interfaces:
  moorlan0:
    public-endpoint: vpn.example:51820
    home-networks:
      - 10.10.0.0/24
      - 10.10.10.0/24
    dns-servers:
      - 10.10.10.1
      - 1.1.1.1
    dns-search:
      - home.arpa
`)
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.DB != "/var/lib/moorlan/moorlan.db" || got.PrivateEndpoint != "10.10.10.1:8756" {
		t.Fatalf("root: %+v", got)
	}
	iface, ok := got.Lookup("moorlan0")
	if !ok {
		t.Fatal("missing iface")
	}
	if iface.PublicEndpoint != "vpn.example:51820" {
		t.Fatalf("public-endpoint: %q", iface.PublicEndpoint)
	}
	if len(iface.HomeNetworks) != 2 || iface.HomeNetworks[0] != "10.10.0.0/24" || iface.HomeNetworks[1] != "10.10.10.0/24" {
		t.Fatalf("home-networks: %v", iface.HomeNetworks)
	}
	if len(iface.DNSServers) != 2 || iface.DNSServers[0] != "10.10.10.1" || iface.DNSServers[1] != "1.1.1.1" {
		t.Fatalf("dns-servers: %v", iface.DNSServers)
	}
	if len(iface.DNSSearch) != 1 || iface.DNSSearch[0] != "home.arpa" {
		t.Fatalf("dns-search: %v", iface.DNSSearch)
	}
}

func TestLoadMissingHintsExample(t *testing.T) {
	Path = filepath.Join(t.TempDir(), "missing.yaml")
	_, err := Load()
	if err == nil {
		t.Fatal("missing conf accepted")
	}
	if !strings.Contains(err.Error(), Path) || !strings.Contains(err.Error(), ExamplePath) {
		t.Fatalf("missing-conf hint: %v", err)
	}
}

func TestLoadRejectsUnknownKey(t *testing.T) {
	writeSite(t, `
db: /var/lib/moorlan/moorlan.db
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
    peers: bad
`)
	if _, err := Load(); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestLoadRejectsLegacyAndMissingRequired(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces: {}
`)
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	writeSite(t, `
db: /tmp/x.db
interfaces:
  wg0:
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	if _, err := Load(); err == nil {
		t.Fatal("missing private-endpoint accepted")
	}
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	if _, err := Load(); err == nil {
		t.Fatal("missing public-endpoint accepted")
	}
}

func TestInterfaceNamesStableOrder(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg1:
    public-endpoint: vpn.example:51821
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
  wg0:
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	names := got.InterfaceNames()
	if len(names) != 2 || names[0] != "wg0" || names[1] != "wg1" {
		t.Fatalf("%v", names)
	}
}
