package runtime

import (
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"net"
	"testing"

	"peerdoor/internal/iface"
)

func TestSelectLANFollowsRouteInsteadOfDockerBridge(t *testing.T) {
	candidates := []iface.LAN{
		{Device: "docker0", IP: "172.17.0.1", CIDR: "172.17.0.0/16"},
		{Device: "eth0", IP: "192.168.1.10", CIDR: "192.168.1.0/24"},
		{Device: "eth1", IP: "10.0.0.10", CIDR: "10.0.0.0/24"},
	}
	got, err := selectLAN(candidates, "", net.ParseIP("192.168.1.10"))
	if err != nil || got.Device != "eth0" || got.CIDR != "192.168.1.0/24" {
		t.Fatalf("%+v %v", got, err)
	}
	got, err = selectLAN(candidates, "eth1", net.ParseIP("192.168.1.10"))
	if err != nil || got.Device != "eth1" {
		t.Fatalf("explicit interface ignored: %+v %v", got, err)
	}
	if _, err := selectLAN(candidates, "missing", nil); err == nil {
		t.Fatal("missing interface accepted")
	}
	// A default route through an excluded VPN must not choose an arbitrary LAN.
	if _, err := selectLAN(candidates, "", net.ParseIP("10.8.0.1")); err == nil {
		t.Fatal("missing route address accepted")
	}
}

func TestSelectLANMultipleAddresses(t *testing.T) {
	candidates := []iface.LAN{
		{Device: "eth0", IP: "192.168.1.10", CIDR: "192.168.1.0/24"},
		{Device: "eth0", IP: "192.168.1.11", CIDR: "192.168.1.0/24"},
	}
	got, err := selectLAN(candidates, "eth0", net.ParseIP("192.168.1.11"))
	if err != nil || got.IP != "192.168.1.11" {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := selectLAN(candidates, "eth0", nil); err == nil {
		t.Fatal("ambiguous interface address accepted")
	}
}

func TestUnjoinDiscoveryDoesNotRequirePoolOrListeningPort(t *testing.T) {
	device := &wgtypes.Device{PublicKey: wgtypes.Key{1}}
	if err := validateInterface(device, []string{"10.8.0.1/32"}, false); err != nil {
		t.Fatal(err)
	}
	device.ListenPort = 51820
	if err := validateInterface(device, []string{"10.8.0.1/32"}, true); err == nil {
		t.Fatal("pairing must still require a pool")
	}
	device.PublicKey = wgtypes.Key{}
	if err := validateInterface(device, nil, false); err == nil {
		t.Fatal("unjoin needs an existing server identity")
	}
}

func TestConventionalSetupRejectedBeforeEnrollment(t *testing.T) {
	device := &wgtypes.Device{PublicKey: wgtypes.Key{1}, ListenPort: 51820}
	_, broad, _ := net.ParseCIDR("10.8.0.0/25")
	device.Peers = []wgtypes.Peer{{PublicKey: wgtypes.Key{2}, AllowedIPs: []net.IPNet{*broad}}}
	if err := validateInterface(device, []string{"10.8.0.1/24"}, true); err != nil {
		t.Fatal("existing routed range should reserve addresses:", err)
	}
	// Cleanup remains available even when enrollment is unsupported.
	if err := validateInterface(device, []string{"10.8.0.1/32"}, false); err != nil {
		t.Fatal(err)
	}
	_, tunnel, _ := net.ParseCIDR("10.8.0.0/24")
	if err := validateLAN(iface.LAN{IP: "10.8.0.10", CIDR: "10.8.0.0/24"}, tunnel); err == nil {
		t.Fatal("LAN overlaps tunnel")
	}
	if err := validateLAN(iface.LAN{IP: "203.0.113.10", CIDR: "203.0.113.0/24"}, nil); err == nil {
		t.Fatal("public network accepted as home LAN")
	}
	if err := validateLAN(iface.LAN{IP: "192.168.1.10", CIDR: "192.168.1.0/24"}, tunnel); err != nil {
		t.Fatal(err)
	}
}
