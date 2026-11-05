package runtime

import (
	"net"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func TestParseHomeNetworks(t *testing.T) {
	got, err := parseHomeNetworks("10.10.0.0/16")
	if err != nil || len(got) != 1 || got[0] != "10.10.0.0/16" {
		t.Fatalf("%v %v", got, err)
	}
	got, err = parseHomeNetworks("10.10.10.0/24, 10.10.20.0/24,10.10.10.0/24")
	if err != nil || len(got) != 2 || got[0] != "10.10.10.0/24" || got[1] != "10.10.20.0/24" {
		t.Fatalf("dedupe/split: %v %v", got, err)
	}
	if _, err := parseHomeNetworks(""); err == nil {
		t.Fatal("empty home-networks accepted")
	}
	if _, err := parseHomeNetworks("203.0.113.0/24"); err == nil {
		t.Fatal("public home-networks accepted")
	}
	if _, err := parseHomeNetworks("192.168.0.0/15"); err == nil {
		t.Fatal("prefix that spills into public space accepted")
	}
	if _, err := parseHomeNetworks("10.0.0.0/7"); err == nil {
		t.Fatal("prefix wider than 10.0.0.0/8 accepted")
	}
	if _, err := parseHomeNetworks("172.16.0.0/11"); err == nil {
		t.Fatal("prefix wider than 172.16.0.0/12 accepted")
	}
	if _, err := parseHomeNetworks("not-a-cidr"); err == nil {
		t.Fatal("garbage home-networks accepted")
	}
}

func TestResolvePrivateEndpointValidation(t *testing.T) {
	if _, _, err := resolvePrivateEndpoint("wg0", "", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("missing private-endpoint accepted")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "", nil); err == nil {
		t.Fatal("missing private-endpoint accepted without home-networks")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "10.10.10.1", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("private-endpoint without port accepted")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "203.0.113.1:8756", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("public private-endpoint accepted")
	}
}

func TestValidateHomeNetworksRejectsTunnelOverlap(t *testing.T) {
	_, tunnel, _ := net.ParseCIDR("10.8.0.0/24")
	if err := validateHomeNetworks([]string{"10.8.0.0/24"}, tunnel); err == nil {
		t.Fatal("CIDR overlaps tunnel")
	}
	if err := validateHomeNetworks([]string{"203.0.113.0/24"}, nil); err == nil {
		t.Fatal("public network accepted as home-networks")
	}
	if err := validateHomeNetworks([]string{"192.168.0.0/15"}, nil); err == nil {
		t.Fatal("prefix that spills into public space accepted")
	}
	if err := validateHomeNetworks([]string{"192.168.1.0/24", "10.10.0.0/16"}, tunnel); err != nil {
		t.Fatal(err)
	}
}

func TestParseDNSServers(t *testing.T) {
	got, err := parseDNSServers("")
	if err == nil || got != nil {
		t.Fatalf("empty dns-servers should fail: %v %v", got, err)
	}
	got, err = parseDNSServers("10.10.10.1, 1.1.1.1,10.10.10.1")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "10.10.10.1" || got[1] != "1.1.1.1" {
		t.Fatalf("%v", got)
	}
	got, err = parseDNSServers("8.8.8.8")
	if err != nil || len(got) != 1 || got[0] != "8.8.8.8" {
		t.Fatalf("public dns: %v %v", got, err)
	}
	if _, err := parseDNSServers("127.0.0.1"); err == nil {
		t.Fatal("loopback dns accepted")
	}
	if _, err := parseDNSServers("0.0.0.0"); err == nil {
		t.Fatal("unspecified dns accepted")
	}
	if _, err := parseDNSServers("224.0.0.1"); err == nil {
		t.Fatal("multicast dns accepted")
	}
	if _, err := parseDNSServers("not-an-ip"); err == nil {
		t.Fatal("garbage dns accepted")
	}
}

func TestParseDNSSearch(t *testing.T) {
	got, err := parseDNSSearch("home.arpa, LAN.")
	if err != nil || len(got) != 2 || got[0] != "home.arpa" || got[1] != "lan" {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := parseDNSSearch(""); err != nil {
		t.Fatal(err)
	}
	if _, err := parseDNSSearch("-bad.arpa"); err == nil {
		t.Fatal("invalid search domain accepted")
	}
}

func TestValidateInterfaceRequiresUsableDevice(t *testing.T) {
	device := &wgtypes.Device{PublicKey: wgtypes.Key{1}}
	if err := validateInterface(device, []string{"10.8.0.1/24"}); err == nil {
		t.Fatal("missing listen port accepted")
	}
	device.ListenPort = 51820
	if err := validateInterface(device, []string{"10.8.0.1/32"}); err == nil {
		t.Fatal("missing pool prefix accepted")
	}
	if err := validateInterface(device, []string{"10.8.0.1/24"}); err != nil {
		t.Fatal(err)
	}
	device.PublicKey = wgtypes.Key{}
	if err := validateInterface(device, []string{"10.8.0.1/24"}); err == nil {
		t.Fatal("missing server identity accepted")
	}
}

func TestValidateInterfaceReservesRoutedRanges(t *testing.T) {
	device := &wgtypes.Device{PublicKey: wgtypes.Key{1}, ListenPort: 51820}
	_, broad, _ := net.ParseCIDR("10.8.0.0/25")
	device.Peers = []wgtypes.Peer{{PublicKey: wgtypes.Key{2}, AllowedIPs: []net.IPNet{*broad}}}
	if err := validateInterface(device, []string{"10.8.0.1/24"}); err != nil {
		t.Fatal("existing routed range should reserve addresses:", err)
	}
}
