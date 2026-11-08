package settings

import (
	"strings"
	"testing"
)

func TestMergeExistingWins(t *testing.T) {
	existing := Site{
		PrivateEndpoint: "10.0.0.5:8756",
		Interfaces: map[string]Interface{
			"wg0": {
				Enabled: boolPtr(true), Name: "Home", PublicEndpoint: "vpn.example.com:51820",
				HomeNetworks: []string{"10.0.0.0/24"}, DNSServers: []string{"10.8.0.1"},
			},
			"wg_old": {
				Enabled: boolPtr(false), Name: "Old", PublicEndpoint: "1.2.3.4:51820",
				HomeNetworks: []string{"10.0.0.0/24"}, DNSServers: []string{"10.8.0.1"},
			},
		},
	}
	guessed := CreateDefaultConf("10.0.0.9:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Guessed", PublicEndpoint: "9.9.9.9:51820",
			HomeNetworks: []string{"10.0.0.0/24", "10.1.0.0/24"},
			DNSServers:   []string{"10.8.0.1"}, DNSSearch: []string{"home.arpa"},
		},
		"wg1": {
			Name: "New", PublicEndpoint: "8.8.8.8:51821",
			HomeNetworks: []string{"10.0.0.0/24"},
			DNSServers:   []string{"10.9.0.1"}, DNSSearch: []string{"home.arpa"},
		},
	})
	merged, notes := Merge(existing, guessed)
	if merged.PrivateEndpoint != "10.0.0.5:8756" {
		t.Fatalf("private-endpoint: %s", merged.PrivateEndpoint)
	}
	wg0 := merged.Interfaces["wg0"]
	if wg0.Enabled == nil || !*wg0.Enabled || wg0.Name != "Home" || wg0.PublicEndpoint != "vpn.example.com:51820" {
		t.Fatalf("wg0: %+v", wg0)
	}
	if wg1, ok := merged.Interfaces["wg1"]; !ok || wg1.Enabled == nil || *wg1.Enabled {
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

func TestMergeIncompleteExistingFillsFromGuess(t *testing.T) {
	existing, err := Parse([]byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.8.0.1]
`))
	if err != nil {
		t.Fatal(err)
	}
	guessed := CreateDefaultConf("10.0.0.9:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Guessed", PublicEndpoint: "9.9.9.9:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.8.0.1"},
			DNSSearch:    []string{"home.arpa"},
		},
	})
	merged, _ := Merge(existing, guessed)
	if err := Validate(merged); err != nil {
		t.Fatal(err)
	}
	wg0 := merged.Interfaces["wg0"]
	if wg0.Name != "Home" || wg0.PublicEndpoint != "vpn.example:51820" {
		t.Fatalf("existing fields must win: %+v", wg0)
	}
	if wg0.Enabled == nil || *wg0.Enabled || len(wg0.DNSSearch) != 1 || wg0.DNSSearch[0] != "home.arpa" {
		t.Fatalf("unset fields from guess: %+v", wg0)
	}
	body, err := Encode(merged)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "enabled:") {
		t.Fatalf("encode must emit all site keys:\n%s", body)
	}
}

func TestMergeFillsMissingPublicEndpoint(t *testing.T) {
	existing, err := Parse([]byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    enabled: false
    name: Home
    home-networks: [10.10.0.0/24]
    dns-servers: [10.8.0.1]
`))
	if err != nil {
		t.Fatal(err)
	}
	guessed := CreateDefaultConf("10.10.10.1:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Home", PublicEndpoint: "203.0.113.1:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.8.0.1"},
		},
	})
	merged, _ := Merge(existing, guessed)
	if err := Validate(merged); err != nil {
		t.Fatal(err)
	}
	if merged.Interfaces["wg0"].PublicEndpoint != "203.0.113.1:51820" {
		t.Fatalf("%+v", merged.Interfaces["wg0"])
	}
}

func TestMergeAddsNewIfaceDropsUnknownOnEncode(t *testing.T) {
	existing, err := Parse([]byte(`
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example:51820
    home-networks: [10.10.0.0/24]
    dns-servers: [10.8.0.1]
    deprecated: yes
`))
	if err != nil {
		t.Fatal(err)
	}
	guessed := CreateDefaultConf("10.10.10.1:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Home", PublicEndpoint: "vpn.example:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.8.0.1"},
		},
		"wg1": {
			Name: "Cabin", PublicEndpoint: "vpn.example:51821",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.9.0.1"},
		},
	})
	merged, notes := Merge(existing, guessed)
	if err := Validate(merged); err != nil {
		t.Fatal(err)
	}
	if _, ok := merged.Interfaces["wg1"]; !ok {
		t.Fatal("wg1 not added")
	}
	body, err := Encode(merged)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "deprecated") {
		t.Fatalf("deprecated key survived encode:\n%s", body)
	}
	if !strings.Contains(strings.Join(notes, " "), "wg1") {
		t.Fatalf("notes: %v", notes)
	}
}

func TestMergeKeepsOrphanIface(t *testing.T) {
	existing := Site{
		PrivateEndpoint: "10.10.10.1:8756",
		Interfaces: map[string]Interface{
			"wg_old": {
				Enabled: boolPtr(true), Name: "Old",
				PublicEndpoint: "1.2.3.4:51820",
				HomeNetworks:   []string{"10.10.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
			},
		},
	}
	guessed := CreateDefaultConf("10.10.10.1:8756", nil)
	merged, notes := Merge(existing, guessed)
	if err := Validate(merged); err != nil {
		t.Fatal(err)
	}
	if merged.Interfaces["wg_old"].Enabled == nil || !*merged.Interfaces["wg_old"].Enabled {
		t.Fatal("orphan lost enabled")
	}
	if !strings.Contains(strings.Join(notes, " "), "wg_old") {
		t.Fatalf("%v", notes)
	}
}
