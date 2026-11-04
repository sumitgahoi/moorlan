package runtime

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/iface"
	"moorlan/internal/payload"
)

type Host struct {
	Snap       iface.Snapshot
	PairIP     string
	HomeCIDRs  []string
	ConfPath   string
	PairHost   string
	PairPort   int
	Endpoint   string
}

func Discover(wgName, wgConf, privateEndpoint, homeCIDRs, publicEndpoint string) (Host, error) {
	return discover(wgName, wgConf, privateEndpoint, homeCIDRs, publicEndpoint, true)
}

// DiscoverUnpair needs only the existing device, private control address, and save configuration.
func DiscoverUnpair(wgName, wgConf, privateEndpoint, homeCIDRs string) (Host, error) {
	return discover(wgName, wgConf, privateEndpoint, homeCIDRs, "", false)
}

func discover(wgName, wgConf, privateEndpoint, homeCIDRs, publicEndpoint string, pairing bool) (Host, error) {
	if runtime.GOOS != "linux" {
		return Host{}, fmt.Errorf("Moorlan server requires Linux")
	}
	if !validInterfaceName(wgName) {
		return Host{}, fmt.Errorf("invalid WireGuard interface name")
	}
	client, err := wgctrl.New()
	if err != nil {
		return Host{}, err
	}
	defer client.Close()
	device, err := client.Device(wgName)
	if err != nil {
		return Host{}, fmt.Errorf("read WireGuard interface %s: %w", wgName, err)
	}
	addrs, mtu, err := interfaceAddresses(wgName)
	if err != nil {
		return Host{}, err
	}
	cidrs, err := parseHomeCIDRs(homeCIDRs)
	if err != nil {
		return Host{}, err
	}
	pairIP, pairPort, err := resolvePrivateEndpoint(wgName, privateEndpoint, cidrs)
	if err != nil {
		return Host{}, err
	}
	var subnet *net.IPNet
	if pairing {
		pool, err := iface.SelectPool(addrs)
		if err != nil {
			return Host{}, err
		}
		subnet = pool.Network
	}
	if err := validateHomeCIDRs(cidrs, subnet); err != nil {
		return Host{}, err
	}
	if err := validateInterface(device, addrs, pairing); err != nil {
		return Host{}, err
	}
	if wgConf == "" {
		wgConf = filepath.Join("/etc/wireguard", wgName+".conf")
	}
	wgConf, err = filepath.Abs(wgConf)
	if err != nil {
		return Host{}, err
	}
	if filepath.Base(wgConf) != wgName+".conf" {
		return Host{}, fmt.Errorf("wg-quick config filename must be %s.conf", wgName)
	}
	info, err := os.Lstat(wgConf)
	if err != nil {
		return Host{}, err
	}
	if !info.Mode().IsRegular() {
		return Host{}, fmt.Errorf("unsupported config: use a regular wg-quick file, not a symlink")
	}
	if _, err := os.ReadFile(wgConf); err != nil {
		return Host{}, fmt.Errorf("read wg-quick configuration: %w", err)
	}
	if publicEndpoint != "" {
		if _, _, err := payload.SplitEndpoint(publicEndpoint); err != nil {
			return Host{}, err
		}
	}
	return Host{
		Snap: iface.Snapshot{
			Name:       wgName,
			PublicKey:  device.PublicKey.String(),
			ListenPort: device.ListenPort,
			MTU:        mtu,
			Addresses:  addrs,
		},
		PairIP:    pairIP,
		HomeCIDRs: cidrs,
		ConfPath:  wgConf,
		PairHost:  pairIP,
		PairPort:  pairPort,
		Endpoint:  publicEndpoint,
	}, nil
}

func validateInterface(device *wgtypes.Device, addresses []string, pairing bool) error {
	if device.PublicKey == (wgtypes.Key{}) {
		return fmt.Errorf("WireGuard has no configured key")
	}
	if !pairing {
		return nil
	}
	if device.ListenPort == 0 {
		return fmt.Errorf("WireGuard has no listening port")
	}
	pool, err := iface.SelectPool(addresses)
	if err != nil {
		return err
	}
	_, err = iface.Occupied(pool, devicePeers(device))
	return err
}

func interfaceAddresses(name string) ([]string, int, error) {
	device, err := net.InterfaceByName(name)
	if err != nil {
		return nil, 0, err
	}
	addresses, err := device.Addrs()
	if err != nil {
		return nil, 0, err
	}
	var out []string
	for _, address := range addresses {
		out = append(out, address.String())
	}
	return out, device.MTU, nil
}

// RFC 1918 + RFC 6598 (same IPv4 ranges as net.IP.IsPrivate).
var privateIPv4Blocks = []*net.IPNet{
	{IP: net.IP{10, 0, 0, 0}, Mask: net.CIDRMask(8, 32)},
	{IP: net.IP{172, 16, 0, 0}, Mask: net.CIDRMask(12, 32)},
	{IP: net.IP{192, 168, 0, 0}, Mask: net.CIDRMask(16, 32)},
	{IP: net.IP{100, 64, 0, 0}, Mask: net.CIDRMask(10, 32)},
}

// ipv4PrefixFullyPrivate reports whether every address in network lies inside one
// private IPv4 block. Checking only network.IP.IsPrivate accepts prefixes such as
// 192.168.0.0/15 that also cover public space.
func ipv4PrefixFullyPrivate(network *net.IPNet) bool {
	ip4 := network.IP.To4()
	if ip4 == nil {
		return false
	}
	ones, bits := network.Mask.Size()
	if bits != 32 || ones < 0 {
		return false
	}
	for _, block := range privateIPv4Blocks {
		blockOnes, _ := block.Mask.Size()
		if block.Contains(ip4) && ones >= blockOnes {
			return true
		}
	}
	return false
}

func parseHomeCIDRs(text string) ([]string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, fmt.Errorf("home CIDRs required; pass -home-cidrs (for example -home-cidrs 10.10.0.0/16)")
	}
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(text, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		_, network, err := net.ParseCIDR(part)
		if err != nil {
			return nil, fmt.Errorf("invalid -home-cidrs CIDR %q", part)
		}
		ones, bits := network.Mask.Size()
		if network.IP.To4() == nil || bits != 32 || ones < 8 || ones > 32 {
			return nil, fmt.Errorf("unsupported -home-cidrs %s: use an IPv4 prefix from /8 through /32", network)
		}
		if !ipv4PrefixFullyPrivate(network) {
			return nil, fmt.Errorf("unsupported -home-cidrs %s: entire prefix must lie in a private IPv4 range", network)
		}
		cidr := network.String()
		if seen[cidr] {
			continue
		}
		seen[cidr] = true
		out = append(out, cidr)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("home CIDRs required; pass -home-cidrs (for example -home-cidrs 10.10.0.0/16)")
	}
	return out, nil
}

func resolvePrivateEndpoint(wgName, endpoint string, homeCIDRs []string) (string, int, error) {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		return "", 0, fmt.Errorf("private endpoint required; pass -private-endpoint (for example -private-endpoint 10.10.10.1:8756)")
	}
	host, portText, err := payload.SplitEndpoint(endpoint)
	if err != nil {
		return "", 0, fmt.Errorf("invalid -private-endpoint: %w", err)
	}
	port, _ := strconv.Atoi(portText)
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
		return "", 0, fmt.Errorf("unsupported -private-endpoint host %s: use a private IPv4 address configured on this host", host)
	}
	ip = ip.To4()
	if !localIPv4Configured(wgName, ip) {
		return "", 0, fmt.Errorf("-private-endpoint host %s is not configured on this host", ip)
	}
	for _, cidr := range homeCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err == nil && network.Contains(ip) {
			return ip.String(), port, nil
		}
	}
	return "", 0, fmt.Errorf("-private-endpoint host %s is outside -home-cidrs (%s)", ip, strings.Join(homeCIDRs, ","))
}

func localIPv4Configured(wgName string, want net.IP) bool {
	devices, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, device := range devices {
		if device.Name == wgName || device.Flags&net.FlagUp == 0 || device.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := device.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil || ip.To4() == nil {
				continue
			}
			if ip.To4().Equal(want) {
				return true
			}
		}
	}
	return false
}

func validateHomeCIDRs(homeCIDRs []string, tunnel *net.IPNet) error {
	for _, cidr := range homeCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil || !ipv4PrefixFullyPrivate(network) {
			return fmt.Errorf("unsupported home CIDR: entire prefix must lie in a private IPv4 range")
		}
		if tunnel != nil && (tunnel.Contains(network.IP) || network.Contains(tunnel.IP)) {
			return fmt.Errorf("unsupported setup: WireGuard subnet and home CIDR %s must not overlap", cidr)
		}
	}
	return nil
}

func devicePeers(device *wgtypes.Device) []iface.Peer {
	out := make([]iface.Peer, 0, len(device.Peers))
	for _, peer := range device.Peers {
		item := iface.Peer{PublicKey: peer.PublicKey.String()}
		for _, address := range peer.AllowedIPs {
			item.AllowedIPs = append(item.AllowedIPs, address.String())
		}
		out = append(out, item)
	}
	return out
}

// HomeCIDRLease returns the lease lan field (comma-separated CIDRs for away routes).
func (h Host) HomeCIDRLease() string {
	return strings.Join(h.HomeCIDRs, ",")
}

// RoutePrefixes is the tunnel pool plus every home CIDR.
func (h Host) RoutePrefixes(poolNetwork string) []string {
	out := make([]string, 0, 1+len(h.HomeCIDRs))
	if poolNetwork != "" {
		out = append(out, poolNetwork)
	}
	out = append(out, h.HomeCIDRs...)
	return out
}
