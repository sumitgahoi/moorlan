package iface

import "testing"

func TestAllocateSkipsReservedAddressesAndReusesKey(t *testing.T) {
	pool, err := SelectPool([]string{"10.8.0.1/24", "fd00::1/64"})
	if err != nil {
		t.Fatal(err)
	}
	peers := []Peer{{PublicKey: "first", AllowedIPs: []string{"10.8.0.2/32"}}, {PublicKey: "third", AllowedIPs: []string{"10.8.0.4/32"}}}
	ip, err := Allocate(pool, peers, "new")
	if err != nil || ip.String() != "10.8.0.3" {
		t.Fatalf("%s %v", ip, err)
	}
	ip, err = Allocate(pool, peers, "first")
	if err != nil || ip.String() != "10.8.0.2" {
		t.Fatalf("retry: %s %v", ip, err)
	}
}
func TestSelectPoolRejectsUnsupportedLayouts(t *testing.T) {
	for _, addresses := range [][]string{
		{}, {"fd00::1/64"}, {"10.8.0.1/32"}, {"10.8.0.1/31"}, {"10.8.0.1/8"},
		{"203.0.113.1/24"}, {"10.8.0.1/24", "10.8.0.2/24"},
		{"10.8.0.0/24"}, {"10.8.0.255/24"},
	} {
		if _, err := SelectPool(addresses); err == nil {
			t.Fatalf("accepted unsupported addresses %v", addresses)
		}
	}
	for _, address := range []string{"10.8.0.1/16", "10.8.0.1/24", "172.16.0.1/24", "192.168.50.1/30"} {
		if _, err := SelectPool([]string{address}); err != nil {
			t.Fatal(err)
		}
	}
}
func TestPoolExhaustionStillAllowsRetry(t *testing.T) {
	pool, _ := SelectPool([]string{"10.8.0.1/30"})
	peers := []Peer{{PublicKey: "phone", AllowedIPs: []string{"10.8.0.2/32"}}}
	if _, err := Allocate(pool, peers, "new"); err == nil {
		t.Fatal("expected exhaustion")
	}
	if _, err := Allocate(pool, peers, "phone"); err != nil {
		t.Fatalf("existing device cannot retry: %v", err)
	}
	if _, err := Occupied(pool, peers); err != nil {
		t.Fatalf("full pool rejected at startup: %v", err)
	}
}
func TestRejectsReservedAddresses(t *testing.T) {
	pool, _ := SelectPool([]string{"10.8.0.1/24"})
	for _, peers := range [][]Peer{
		{{PublicKey: "a", AllowedIPs: []string{"10.8.0.1/32"}}},
		{{PublicKey: "a", AllowedIPs: []string{"10.8.0.0/32"}}},
		{{PublicKey: "a", AllowedIPs: []string{"10.8.0.255/32"}}},
	} {
		if _, err := Allocate(pool, peers, "new"); err == nil {
			t.Fatalf("accepted conflict: %v", peers)
		}
	}
}
func TestExistingComplexPeerIsNotReconfigured(t *testing.T) {
	pool, _ := SelectPool([]string{"10.8.0.1/24"})
	peers := []Peer{{PublicKey: "router", AllowedIPs: []string{"10.8.0.2/32", "192.168.50.0/24"}}}
	if _, err := Allocate(pool, peers, "router"); err == nil {
		t.Fatal("reused complex peer")
	}
	ip, err := Allocate(pool, peers, "phone")
	if err != nil || ip.String() != "10.8.0.3" {
		t.Fatalf("%s %v", ip, err)
	}
}

func TestExistingRoutedRangesAreReserved(t *testing.T) {
	pool, _ := SelectPool([]string{"10.8.0.1/24"})
	for _, tc := range []struct{ route, want string }{
		{"10.8.0.0/28", "10.8.0.16"}, {"10.8.0.2/31", "10.8.0.4"},
		{"10.8.0.128/25", "10.8.0.2"}, {"192.168.0.0/16", "10.8.0.2"},
	} {
		ip, err := Allocate(pool, []Peer{{PublicKey: "router", AllowedIPs: []string{tc.route}}}, "phone")
		if err != nil || ip.String() != tc.want {
			t.Fatalf("%s: %v %v", tc.route, ip, err)
		}
	}
	if _, err := Allocate(pool, []Peer{{PublicKey: "router", AllowedIPs: []string{"0.0.0.0/0"}}}, "phone"); err == nil {
		t.Fatal("full range allocated")
	}
}
