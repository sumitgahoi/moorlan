package runtime

import (
	"fmt"
	"net"
	"runtime"
	"strconv"
	"strings"

	"moorlan/internal/iface"
	"moorlan/internal/payload"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

type Host struct {
	Snap      iface.Snapshot
	StorePath string
	PairIP    string
	HomeCIDRs []string
	DNS       []string
	PairHost  string
	PairPort  int
	Endpoint  string
}

// Discover opens an existing moorlanN device for pairing (needs pool + listen port).
func Discover(wgName, storePath, privateEndpoint, homeCIDRs, publicEndpoint, dns string) (Host, error) {
	host, err := discover(wgName, storePath, privateEndpoint, homeCIDRs, publicEndpoint, true)
	if err != nil {
		return Host{}, err
	}
	pool, err := iface.SelectPool(host.Snap.Addresses)
	if err != nil {
		return Host{}, err
	}
	servers, err := parseDNSServers(dns, host.HomeCIDRs, pool.Own)
	if err != nil {
		return Host{}, err
	}
	host.DNS = servers
	return host, nil
}

// DiscoverUnpair opens the device for the unpair HTTP service.
// Only -private-endpoint is required (listen address); home CIDRs are for pairing leases.
func DiscoverUnpair(wgName, storePath, privateEndpoint string) (Host, error) {
	host, err := DiscoverDevice(wgName, storePath)
	if err != nil {
		return Host{}, err
	}
	pairIP, pairPort, err := resolvePrivateEndpoint(wgName, privateEndpoint, nil)
	if err != nil {
		return Host{}, err
	}
	host.PairIP = pairIP
	host.PairHost = pairIP
	host.PairPort = pairPort
	return host, nil
}

// DiscoverDevice opens the device for rehydrate or --remove (no LAN control address).
func DiscoverDevice(wgName, storePath string) (Host, error) {
	return discover(wgName, storePath, "", "", "", false)
}

func discover(wgName, storePath, privateEndpoint, homeCIDRs, publicEndpoint string, pairing bool) (Host, error) {
	if runtime.GOOS != "linux" {
		return Host{}, fmt.Errorf("Moorlan server requires Linux")
	}
	if err := validateInterfaceName(wgName); err != nil {
		return Host{}, err
	}
	client, err := wgctrl.New()
	if err != nil {
		return Host{}, err
	}
	defer client.Close()
	device, err := client.Device(wgName)
	if err != nil {
		return Host{}, fmt.Errorf("read WireGuard interface %s: %w (create device %s first)", wgName, err, wgName)
	}
	addrs, mtu, err := interfaceAddresses(wgName)
	if err != nil {
		return Host{}, err
	}
	if err := validateInterface(device, addrs); err != nil {
		return Host{}, err
	}
	if storePath == "" {
		storePath = DefaultStorePath(wgName)
	}
	host := Host{
		Snap: iface.Snapshot{
			Name:       wgName,
			PublicKey:  device.PublicKey.String(),
			ListenPort: device.ListenPort,
			MTU:        mtu,
			Addresses:  addrs,
		},
		StorePath: storePath,
		Endpoint:  publicEndpoint,
	}
	if privateEndpoint == "" && homeCIDRs == "" {
		if publicEndpoint != "" {
			if _, _, err := payload.SplitEndpoint(publicEndpoint); err != nil {
				return Host{}, err
			}
		}
		return host, nil
	}
	cidrs, err := parseHomeCIDRs(homeCIDRs)
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
	pairIP, pairPort, err := resolvePrivateEndpoint(wgName, privateEndpoint, cidrs)
	if err != nil {
		return Host{}, err
	}
	if publicEndpoint == "" {
		return Host{}, fmt.Errorf("public-endpoint required (DDNS or static host:port)")
	}
	if _, _, err := payload.SplitEndpoint(publicEndpoint); err != nil {
		return Host{}, err
	}
	host.HomeCIDRs = cidrs
	host.PairIP = pairIP
	host.PairHost = pairIP
	host.PairPort = pairPort
	return host, nil
}

// validateInterface requires a usable WireGuard device. Rehydrate fails (and
// systemd retries) until listen port and the private IPv4 pool are present.
func validateInterface(device *wgtypes.Device, addresses []string) error {
	if device.PublicKey == (wgtypes.Key{}) {
		return fmt.Errorf("WireGuard has no configured key")
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
		return nil, fmt.Errorf("home CIDRs required; pass -home-cidrs (for example -home-cidrs 10.10.0.0/24,10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24)")
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
		return nil, fmt.Errorf("home CIDRs required; pass -home-cidrs (for example -home-cidrs 10.10.0.0/24,10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24)")
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
	if len(homeCIDRs) == 0 {
		return ip.String(), port, nil
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

// parseDNSServers resolves optional lease DNS. Empty text means no DNS in the
// lease (phone keeps its own fallback). Explicit values must be the WireGuard
// tunnel address or lie inside home CIDRs so phones can reach them over the
// leased routes.
func parseDNSServers(text string, homeCIDRs []string, tunnelOwn net.IP) ([]string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, nil
	}
	own := tunnelOwn.To4()
	var networks []*net.IPNet
	for _, cidr := range homeCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid home CIDR %q", cidr)
		}
		networks = append(networks, network)
	}
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(text, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		ip := net.ParseIP(part)
		if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
			return nil, fmt.Errorf("unsupported -dns %q: use the tunnel address or a private IPv4 inside -home-cidrs", part)
		}
		ip = ip.To4()
		ok := own != nil && ip.Equal(own)
		if !ok {
			for _, network := range networks {
				if network.Contains(ip) {
					ok = true
					break
				}
			}
		}
		if !ok {
			hint := strings.Join(homeCIDRs, ",")
			if own != nil {
				return nil, fmt.Errorf("-dns %s must be the WireGuard tunnel address (%s) or inside -home-cidrs (%s)", ip, own, hint)
			}
			return nil, fmt.Errorf("-dns %s must be inside -home-cidrs (%s)", ip, hint)
		}
		addr := ip.String()
		if seen[addr] {
			continue
		}
		seen[addr] = true
		out = append(out, addr)
	}
	return out, nil
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
