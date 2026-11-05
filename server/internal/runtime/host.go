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
	Snap         iface.Snapshot
	StorePath    string
	PairIP       string
	HomeNetworks []string
	DNSServers   []string
	DNSSearch    []string
	PairHost     string
	PairPort     int
	Endpoint     string
}

// Discover opens an existing WireGuard device for pairing (needs pool + listen port).
func Discover(wgName, storePath, privateEndpoint, homeNetworks, publicEndpoint, dnsServers, dnsSearch string) (Host, error) {
	host, err := discover(wgName, storePath, privateEndpoint, homeNetworks, publicEndpoint, true)
	if err != nil {
		return Host{}, err
	}
	servers, err := parseDNSServers(dnsServers)
	if err != nil {
		return Host{}, err
	}
	search, err := parseDNSSearch(dnsSearch)
	if err != nil {
		return Host{}, err
	}
	if len(search) > 0 && len(servers) == 0 {
		return Host{}, fmt.Errorf("dns-search requires dns-servers (point phones at the resolver that serves those domains)")
	}
	host.DNSServers = servers
	host.DNSSearch = search
	return host, nil
}

// DiscoverUnpair opens the device for the unpair HTTP service.
// Only private-endpoint is required (listen address); home-networks are for pairing leases.
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

// DiscoverDevice opens the device for reconcile or --remove (no LAN control address).
func DiscoverDevice(wgName, storePath string) (Host, error) {
	return discover(wgName, storePath, "", "", "", false)
}

func discover(wgName, storePath, privateEndpoint, homeNetworks, publicEndpoint string, pairing bool) (Host, error) {
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
	if privateEndpoint == "" && homeNetworks == "" {
		if publicEndpoint != "" {
			if _, _, err := payload.SplitEndpoint(publicEndpoint); err != nil {
				return Host{}, err
			}
		}
		return host, nil
	}
	cidrs, err := parseHomeNetworks(homeNetworks)
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
	if err := validateHomeNetworks(cidrs, subnet); err != nil {
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
	host.HomeNetworks = cidrs
	host.PairIP = pairIP
	host.PairHost = pairIP
	host.PairPort = pairPort
	return host, nil
}

// validateInterface requires a usable WireGuard device. Reconcile fails (and
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

func parseHomeNetworks(text string) ([]string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, fmt.Errorf("home-networks required (for example home-networks=10.10.0.0/24,10.10.10.0/24)")
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
			return nil, fmt.Errorf("invalid home-networks CIDR %q", part)
		}
		ones, bits := network.Mask.Size()
		if network.IP.To4() == nil || bits != 32 || ones < 8 || ones > 32 {
			return nil, fmt.Errorf("unsupported home-networks %s: use an IPv4 prefix from /8 through /32", network)
		}
		if !ipv4PrefixFullyPrivate(network) {
			return nil, fmt.Errorf("unsupported home-networks %s: entire prefix must lie in a private IPv4 range", network)
		}
		cidr := network.String()
		if seen[cidr] {
			continue
		}
		seen[cidr] = true
		out = append(out, cidr)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("home-networks required (for example home-networks=10.10.0.0/24,10.10.10.0/24)")
	}
	return out, nil
}

func resolvePrivateEndpoint(wgName, endpoint string, homeNetworks []string) (string, int, error) {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		return "", 0, fmt.Errorf("private-endpoint required (for example private-endpoint=10.10.10.1:8756)")
	}
	host, portText, err := payload.SplitEndpoint(endpoint)
	if err != nil {
		return "", 0, fmt.Errorf("invalid private-endpoint: %w", err)
	}
	port, _ := strconv.Atoi(portText)
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
		return "", 0, fmt.Errorf("unsupported private-endpoint host %s: use a private IPv4 address configured on this host", host)
	}
	ip = ip.To4()
	if !localIPv4Configured(wgName, ip) {
		return "", 0, fmt.Errorf("private-endpoint host %s is not configured on this host", ip)
	}
	if len(homeNetworks) == 0 {
		return ip.String(), port, nil
	}
	for _, cidr := range homeNetworks {
		_, network, err := net.ParseCIDR(cidr)
		if err == nil && network.Contains(ip) {
			return ip.String(), port, nil
		}
	}
	return "", 0, fmt.Errorf("private-endpoint host %s is outside home-networks (%s)", ip, strings.Join(homeNetworks, ","))
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

func validateHomeNetworks(homeNetworks []string, tunnel *net.IPNet) error {
	for _, cidr := range homeNetworks {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil || !ipv4PrefixFullyPrivate(network) {
			return fmt.Errorf("unsupported home-networks: entire prefix must lie in a private IPv4 range")
		}
		if tunnel != nil && (tunnel.Contains(network.IP) || network.Contains(tunnel.IP)) {
			return fmt.Errorf("unsupported setup: WireGuard subnet and home-networks %s must not overlap", cidr)
		}
	}
	return nil
}

// parseDNSServers requires one or more unicast IPv4 resolvers (private or public).
func parseDNSServers(text string) ([]string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, fmt.Errorf("dns-servers required (unicast IPv4 resolvers, e.g. dns-servers=10.10.10.53 or 1.1.1.1)")
	}
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(text, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		ip := net.ParseIP(part)
		if ip == nil || ip.To4() == nil {
			return nil, fmt.Errorf("unsupported dns-servers %q: use a unicast IPv4 address", part)
		}
		ip = ip.To4()
		if ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || ip[0] == 255 {
			return nil, fmt.Errorf("unsupported dns-servers %s: use a unicast IPv4 address", ip)
		}
		// Reject limited broadcast and class-E / experimental as non-unicast for resolvers.
		if ip.Equal(net.IPv4bcast) {
			return nil, fmt.Errorf("unsupported dns-servers %s: use a unicast IPv4 address", ip)
		}
		addr := ip.String()
		if seen[addr] {
			continue
		}
		seen[addr] = true
		out = append(out, addr)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("dns-servers required (unicast IPv4 resolvers, e.g. dns-servers=10.10.10.53 or 1.1.1.1)")
	}
	return out, nil
}

// parseDNSSearch parses optional search domains (e.g. home.arpa) so short names
// like "carbon" expand the same way they do on the LAN.
func parseDNSSearch(text string) ([]string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, nil
	}
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(text, ",") {
		part = strings.ToLower(strings.TrimSpace(part))
		part = strings.TrimSuffix(part, ".")
		if part == "" {
			continue
		}
		if err := validateDNSSearchDomain(part); err != nil {
			return nil, err
		}
		if seen[part] {
			continue
		}
		seen[part] = true
		out = append(out, part)
	}
	return out, nil
}

func validateDNSSearchDomain(domain string) error {
	if len(domain) > 253 {
		return fmt.Errorf("unsupported dns-search %q: too long", domain)
	}
	labels := strings.Split(domain, ".")
	if len(labels) < 1 {
		return fmt.Errorf("unsupported dns-search %q", domain)
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 {
			return fmt.Errorf("unsupported dns-search %q: empty or oversized label", domain)
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return fmt.Errorf("unsupported dns-search %q: label cannot start or end with '-'", domain)
		}
		for i := 0; i < len(label); i++ {
			c := label[i]
			if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
				continue
			}
			return fmt.Errorf("unsupported dns-search %q: invalid character", domain)
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
