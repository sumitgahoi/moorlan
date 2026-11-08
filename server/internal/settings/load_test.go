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
private-endpoint: 10.10.10.1:8756
interfaces:
  moorlan0:
    enabled: true
    name: Home
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
	if err := Validate(got); err != nil {
		t.Fatal(err)
	}
	if got.PrivateEndpoint != "10.10.10.1:8756" {
		t.Fatalf("root: %+v", got)
	}
	iface, ok := got.Lookup("moorlan0")
	if !ok {
		t.Fatal("missing iface")
	}
	if iface.Enabled == nil || !*iface.Enabled {
		t.Fatal("enabled")
	}
	if iface.Name != "Home" {
		t.Fatalf("name: %q", iface.Name)
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

func TestLoadDoesNotValidate(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	got, err := Load()
	if err != nil {
		t.Fatalf("Load must not validate: %v", err)
	}
	if got.Interfaces["wg0"].Enabled != nil {
		t.Fatal("expected unset enabled")
	}
}

func TestLoadMissingHintsSetup(t *testing.T) {
	Path = filepath.Join(t.TempDir(), "missing.yaml")
	_, err := Load()
	if err == nil {
		t.Fatal("missing conf accepted")
	}
	if !strings.Contains(err.Error(), Path) || !strings.Contains(err.Error(), "--setup") {
		t.Fatalf("missing-conf hint: %v", err)
	}
}

func TestLoadEmptyInterfaces(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces: {}
`)
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := Validate(got); err != nil {
		t.Fatal(err)
	}
	if got.PrivateEndpoint != "10.10.10.1:8756" || len(got.Interfaces) != 0 {
		t.Fatalf("empty interfaces: %+v", got)
	}
}

func TestEnabledInterfaceNames(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg1:
    enabled: false
    name: Cabin
    public-endpoint: vpn.example:51821
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
  wg0:
    enabled: true
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	enabled := got.EnabledInterfaceNames()
	if len(enabled) != 1 || enabled[0] != "wg0" {
		t.Fatalf("%v", enabled)
	}
}

func TestInterfaceNamesStableOrder(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg1:
    enabled: true
    name: Cabin
    public-endpoint: vpn.example:51821
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
  wg0:
    enabled: false
    name: Home
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
