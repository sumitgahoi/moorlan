package settings

import (
	"os"
	"strings"
	"testing"
)

func TestLoadRoundTripKeys(t *testing.T) {
	Dir = t.TempDir()
	path := Path("moorlan0")
	raw := strings.Join([]string{
		"interface=moorlan0",
		"db=/var/lib/moorlan/moorlan0.db",
		"private-endpoint=10.10.10.1:8756",
		"home-networks=10.10.0.0/24,10.10.10.0/24",
		"public-endpoint=vpn.example:51820",
		"dns-servers=10.10.10.1,1.1.1.1",
		"dns-search=home.arpa",
		"",
	}, "\n")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load("moorlan0")
	if err != nil {
		t.Fatal(err)
	}
	want := Site{
		Interface:       "moorlan0",
		DB:              "/var/lib/moorlan/moorlan0.db",
		PrivateEndpoint: "10.10.10.1:8756",
		HomeNetworks:    "10.10.0.0/24,10.10.10.0/24",
		PublicEndpoint:  "vpn.example:51820",
		DNSServers:      "10.10.10.1,1.1.1.1",
		DNSSearch:       "home.arpa",
	}
	if got != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func TestLoadMissingHintsExample(t *testing.T) {
	Dir = t.TempDir()
	_, err := Load("moorlan1")
	if err == nil {
		t.Fatal("missing conf accepted")
	}
	if !strings.Contains(err.Error(), Path("moorlan1")) || !strings.Contains(err.Error(), ExamplePath) {
		t.Fatalf("missing-conf hint: %v", err)
	}
}

func TestLoadRejectsUnknownKeyAndMismatchedInterface(t *testing.T) {
	Dir = t.TempDir()
	path := Path("moorlan0")
	if err := os.WriteFile(path, []byte("interface=moorlan0\npeers=bad\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load("moorlan0"); err == nil {
		t.Fatal("unknown key accepted")
	}
	if err := os.WriteFile(path, []byte("interface=moorlan1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load("moorlan0"); err == nil {
		t.Fatal("mismatched interface accepted")
	}
}

func TestLoadRejectsLegacyKeys(t *testing.T) {
	Dir = t.TempDir()
	path := Path("moorlan0")
	for _, raw := range []string{
		"interface=moorlan0\nwg=moorlan0\n",
		"interface=moorlan0\nhome-cidrs=10.10.0.0/24\n",
		"interface=moorlan0\ndns=10.10.10.1\n",
		"interface=moorlan0\nunit=networkd\n",
	} {
		if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load("moorlan0"); err == nil {
			t.Fatalf("legacy key accepted in %q", raw)
		}
	}
}

func TestListIfaceNames(t *testing.T) {
	Dir = t.TempDir()
	names, err := ListIfaceNames()
	if err != nil || len(names) != 0 {
		t.Fatalf("%v %v", names, err)
	}
	if err := os.WriteFile(Path("wg0"), []byte("interface=wg0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path("wg1"), []byte("interface=wg1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	names, err = ListIfaceNames()
	if err != nil || len(names) != 2 || names[0] != "wg0" || names[1] != "wg1" {
		t.Fatalf("%v %v", names, err)
	}
}
