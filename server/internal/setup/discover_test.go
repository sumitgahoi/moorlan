package setup

import (
	"net"
	"testing"

	"moorlan/internal/settings"
)

func TestMergeViaDiscoverHelpers(t *testing.T) {
	// Unit-test helpers that don't need live WireGuard.
	prefixes := []string{"10.0.0.0/24"}
	ip := net.ParseIP("10.0.0.5").To4()
	got := ensurePrefixContains(nil, ip)
	if len(got) != 1 || got[0] != "10.0.0.0/24" {
		t.Fatalf("%v", got)
	}
	got = ensurePrefixContains(prefixes, ip)
	if len(got) != 1 {
		t.Fatalf("dup: %v", got)
	}

	_, tunnel, _ := net.ParseCIDR("10.8.0.0/24")
	home := filterHomeNetworks([]string{"10.0.0.0/24", "10.8.0.0/24"}, tunnel)
	if len(home) != 1 || home[0] != "10.0.0.0/24" {
		t.Fatalf("%v", home)
	}

	if sanitizeName("", "Home") != "Home" {
		t.Fatal("fallback")
	}
	if sanitizeName("Cabin\x00", "Home") != "Cabin" {
		t.Fatal("control strip")
	}
}

func TestSettingsMergeEmptyGuess(t *testing.T) {
	existing := settings.Site{
		PrivateEndpoint: "10.0.0.1:8756",
		Interfaces:      map[string]settings.Interface{},
	}
	guessed := settings.Site{
		PrivateEndpoint: "10.0.0.2:8756",
		Interfaces: map[string]settings.Interface{
			"wg0": {
				Enabled:        false,
				Name:           "Home",
				PublicEndpoint: "1.1.1.1:51820",
				HomeNetworks:   []string{"10.0.0.0/24"},
				DNSServers:     []string{"10.8.0.1"},
			},
		},
	}
	merged, _ := settings.Merge(existing, guessed)
	if merged.PrivateEndpoint != "10.0.0.1:8756" {
		t.Fatal(merged.PrivateEndpoint)
	}
	if _, ok := merged.Interfaces["wg0"]; !ok {
		t.Fatal("expected wg0")
	}
}
