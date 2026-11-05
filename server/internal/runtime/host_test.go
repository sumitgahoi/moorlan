package runtime

import (
	"net"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func TestParseHomeCIDRs(t *testing.T) {
	got, err := parseHomeCIDRs("10.10.0.0/16")
	if err != nil || len(got) != 1 || got[0] != "10.10.0.0/16" {
		t.Fatalf("%v %v", got, err)
	}
	got, err = parseHomeCIDRs("10.10.10.0/24, 10.10.20.0/24,10.10.10.0/24")
	if err != nil || len(got) != 2 || got[0] != "10.10.10.0/24" || got[1] != "10.10.20.0/24" {
		t.Fatalf("dedupe/split: %v %v", got, err)
	}
	if _, err := parseHomeCIDRs(""); err == nil {
		t.Fatal("empty home CIDRs accepted")
	}
	if _, err := parseHomeCIDRs("203.0.113.0/24"); err == nil {
		t.Fatal("public home CIDR accepted")
	}
	if _, err := parseHomeCIDRs("192.168.0.0/15"); err == nil {
		t.Fatal("prefix that spills into public space accepted")
	}
	if _, err := parseHomeCIDRs("10.0.0.0/7"); err == nil {
		t.Fatal("prefix wider than 10.0.0.0/8 accepted")
	}
	if _, err := parseHomeCIDRs("172.16.0.0/11"); err == nil {
		t.Fatal("prefix wider than 172.16.0.0/12 accepted")
	}
	if _, err := parseHomeCIDRs("not-a-cidr"); err == nil {
		t.Fatal("garbage home CIDR accepted")
	}
}

func TestResolvePrivateEndpointValidation(t *testing.T) {
	if _, _, err := resolvePrivateEndpoint("wg0", "", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("missing private-endpoint accepted")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "", nil); err == nil {
		t.Fatal("missing private-endpoint accepted without home CIDRs")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "10.10.10.1", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("private-endpoint without port accepted")
	}
	if _, _, err := resolvePrivateEndpoint("wg0", "203.0.113.1:8756", []string{"10.10.0.0/16"}); err == nil {
		t.Fatal("public private-endpoint accepted")
	}
}

func TestValidateHomeCIDRsRejectsTunnelOverlap(t *testing.T) {
	_, tunnel, _ := net.ParseCIDR("10.8.0.0/24")
	if err := validateHomeCIDRs([]string{"10.8.0.0/24"}, tunnel); err == nil {
		t.Fatal("CIDR overlaps tunnel")
	}
	if err := validateHomeCIDRs([]string{"203.0.113.0/24"}, nil); err == nil {
		t.Fatal("public network accepted as home CIDR")
	}
	if err := validateHomeCIDRs([]string{"192.168.0.0/15"}, nil); err == nil {
		t.Fatal("prefix that spills into public space accepted")
	}
	if err := validateHomeCIDRs([]string{"192.168.1.0/24", "10.10.0.0/16"}, tunnel); err != nil {
		t.Fatal(err)
	}
}

func TestHostLeaseHelpers(t *testing.T) {
	h := Host{HomeCIDRs: []string{"10.10.10.0/24", "10.10.20.0/24"}}
	if got := h.HomeCIDRLease(); got != "10.10.10.0/24,10.10.20.0/24" {
		t.Fatal(got)
	}
	got := h.RoutePrefixes("10.8.0.0/24")
	if strings.Join(got, ",") != "10.8.0.0/24,10.10.10.0/24,10.10.20.0/24" {
		t.Fatal(got)
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
