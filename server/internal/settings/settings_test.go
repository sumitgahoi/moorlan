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
	if got.PrivateEndpoint != "10.10.10.1:8756" {
		t.Fatalf("root: %+v", got)
	}
	iface, ok := got.Lookup("moorlan0")
	if !ok {
		t.Fatal("missing iface")
	}
	if !iface.Enabled {
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

func TestLoadRequiresEnabled(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.10.10.1]
`)
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "enabled") {
		t.Fatalf("missing enabled: %v", err)
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

func TestLoadRejectsUnknownKey(t *testing.T) {
	writeSite(t, `
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
	if _, err := Load(); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestLoadEmptyInterfacesIsValid(t *testing.T) {
	writeSite(t, `
private-endpoint: 10.10.10.1:8756
interfaces: {}
`)
	got, err := Load()
	if err != nil {
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

func TestMergeExistingWins(t *testing.T) {
	existing := Site{
		PrivateEndpoint: "10.0.0.5:8756",
		Interfaces: map[string]Interface{
			"wg0": {
				Enabled:        true,
				Name:           "Home",
				PublicEndpoint: "vpn.example.com:51820",
				HomeNetworks:   []string{"10.0.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
			},
			"wg_old": {
				Enabled:        false,
				Name:           "Old",
				PublicEndpoint: "1.2.3.4:51820",
				HomeNetworks:   []string{"10.0.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
			},
		},
	}
	guessed := Site{
		PrivateEndpoint: "10.0.0.9:8756",
		Interfaces: map[string]Interface{
			"wg0": {
				Enabled:        false,
				Name:           "Guessed",
				PublicEndpoint: "9.9.9.9:51820",
				HomeNetworks:   []string{"10.0.0.0/24", "10.1.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
				DNSSearch:      []string{"home.arpa"},
			},
			"wg1": {
				Enabled:        false,
				Name:           "New",
				PublicEndpoint: "8.8.8.8:51821",
				HomeNetworks:   []string{"10.0.0.0/24"},
				DNSServers:     []string{"10.9.0.1"},
				DNSSearch:      []string{"home.arpa"},
			},
		},
	}
	merged, notes := Merge(existing, guessed)
	if merged.PrivateEndpoint != "10.0.0.5:8756" {
		t.Fatalf("private-endpoint: %s", merged.PrivateEndpoint)
	}
	wg0 := merged.Interfaces["wg0"]
	if !wg0.Enabled || wg0.Name != "Home" || wg0.PublicEndpoint != "vpn.example.com:51820" {
		t.Fatalf("wg0: %+v", wg0)
	}
	if wg1, ok := merged.Interfaces["wg1"]; !ok || wg1.Enabled {
		t.Fatalf("wg1: %+v ok=%v", wg1, ok)
	}
	if _, ok := merged.Interfaces["wg_old"]; !ok {
		t.Fatal("missing orphan wg_old")
	}
	joined := strings.Join(notes, " ")
	if !strings.Contains(joined, "wg_old") || !strings.Contains(joined, "wg1") {
		t.Fatalf("notes: %v", notes)
	}
}

func TestWriteRoundTrip(t *testing.T) {
	Path = filepath.Join(t.TempDir(), "moorlan.yaml")
	site := Site{
		PrivateEndpoint: "10.10.10.1:8756",
		Interfaces: map[string]Interface{
			"wg0": {
				Enabled:        false,
				Name:           "Home",
				PublicEndpoint: "1.2.3.4:51820",
				HomeNetworks:   []string{"10.10.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
				DNSSearch:      []string{"home.arpa"},
			},
		},
	}
	if err := Write(site); err != nil {
		t.Fatal(err)
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.PrivateEndpoint != site.PrivateEndpoint {
		t.Fatalf("%+v", got)
	}
	iface := got.Interfaces["wg0"]
	if iface.Enabled || iface.Name != "Home" || iface.PublicEndpoint != "1.2.3.4:51820" {
		t.Fatalf("%+v", iface)
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
