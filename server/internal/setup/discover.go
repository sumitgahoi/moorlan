package setup

import (
	"fmt"
	"net"
	"os"
	"strings"

	"moorlan/internal/iface"
	"moorlan/internal/payload"
	"moorlan/internal/settings"

	"golang.zx2c4.com/wireguard/wgctrl"
)

const defaultPairPort = 8756

// StunFunc returns a public IPv4 for public-endpoint guessing.
type StunFunc func() (net.IP, error)

// Discover builds a guessed Site from live WireGuard and LAN state.
// stun may be nil to use StunPublicIP with DefaultSTUNServers.
func Discover(stun StunFunc) (settings.Site, []string, error) {
	if stun == nil {
		stun = func() (net.IP, error) { return StunPublicIP(nil) }
	}
	var notes []string
	client, err := wgctrl.New()
	if err != nil {
		return settings.Site{}, nil, err
	}
	defer client.Close()
	devices, err := client.Devices()
	if err != nil {
		return settings.Site{}, nil, err
	}

	wgNames := map[string]bool{}
	type cand struct {
		name       string
		listenPort int
		ownIP      net.IP
		pool       *net.IPNet
	}
	var candidates []cand
	for _, device := range devices {
		addrs, _, err := interfaceAddresses(device.Name)
		if err != nil {
			notes = append(notes, fmt.Sprintf("skipped %s: %v", device.Name, err))
			continue
		}
		pool, err := iface.SelectPool(addrs)
		if err != nil {
			notes = append(notes, fmt.Sprintf("skipped %s: %v", device.Name, err))
			continue
		}
		if device.ListenPort == 0 {
			notes = append(notes, fmt.Sprintf("skipped %s: no listen port", device.Name))
			continue
		}
		wgNames[device.Name] = true
		candidates = append(candidates, cand{
			name:       device.Name,
			listenPort: device.ListenPort,
			ownIP:      pool.Own,
			pool:       pool.Network,
		})
	}

	lanPrefixes, lanIP, err := lanPrivate(wgNames)
	if err != nil {
		return settings.Site{}, notes, err
	}
	if lanIP == nil {
		return settings.Site{}, notes, fmt.Errorf("no private LAN IPv4 found for private-endpoint (need an up non-WireGuard interface)")
	}
	privateEndpoint := fmt.Sprintf("%s:%d", lanIP, defaultPairPort)
	// Ensure private-endpoint's prefix is in home-networks.
	lanPrefixes = ensurePrefixContains(lanPrefixes, lanIP)

	hostName, _ := os.Hostname()
	hostName = sanitizeName(hostName, "Home")

	var pubIP net.IP
	if ip, err := stun(); err != nil {
		notes = append(notes, fmt.Sprintf("STUN failed: %v", err))
		if g := firstGlobalIPv4(wgNames); g != nil {
			pubIP = g
			notes = append(notes, fmt.Sprintf("using host global IPv4 %s for public-endpoint", g))
		}
	} else {
		pubIP = ip
	}

	site := settings.Site{
		PrivateEndpoint: privateEndpoint,
		Interfaces:      map[string]settings.Interface{},
	}
	for _, c := range candidates {
		home := filterHomeNetworks(lanPrefixes, c.pool)
		if len(home) == 0 {
			notes = append(notes, fmt.Sprintf("skipped %s: no home-networks after excluding tunnel pool", c.name))
			continue
		}
		pub := ""
		if pubIP != nil {
			pub = fmt.Sprintf("%s:%d", pubIP, c.listenPort)
		} else {
			notes = append(notes, fmt.Sprintf("skipped %s: could not guess public-endpoint", c.name))
			continue
		}
		name := hostName
		if len(candidates) > 1 {
			name = sanitizeName(hostName+"-"+c.name, c.name)
		}
		if err := payload.ValidateName(name); err != nil {
			name = sanitizeName(c.name, "Home")
		}
		site.Interfaces[c.name] = settings.Interface{
			Enabled:        false,
			Name:           name,
			PublicEndpoint: pub,
			HomeNetworks:   home,
			DNSServers:     []string{c.ownIP.String()},
			DNSSearch:      []string{"home.arpa"},
		}
	}
	return site, notes, nil
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

func lanPrivate(wgNames map[string]bool) (prefixes []string, firstIP net.IP, err error) {
	devices, err := net.Interfaces()
	if err != nil {
		return nil, nil, err
	}
	seen := map[string]bool{}
	for _, device := range devices {
		if wgNames[device.Name] || device.Flags&net.FlagUp == 0 || device.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := device.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, network, err := net.ParseCIDR(address.String())
			if err != nil || ip.To4() == nil {
				continue
			}
			ip4 := ip.To4()
			if !ip4.IsPrivate() {
				continue
			}
			cidr := network.String()
			if !seen[cidr] {
				seen[cidr] = true
				prefixes = append(prefixes, cidr)
			}
			if firstIP == nil {
				firstIP = ip4
			}
		}
	}
	return prefixes, firstIP, nil
}

func firstGlobalIPv4(wgNames map[string]bool) net.IP {
	devices, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for _, device := range devices {
		if wgNames[device.Name] || device.Flags&net.FlagUp == 0 || device.Flags&net.FlagLoopback != 0 {
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
			ip4 := ip.To4()
			if ip4.IsGlobalUnicast() && !ip4.IsPrivate() {
				return ip4
			}
		}
	}
	return nil
}

func ensurePrefixContains(prefixes []string, ip net.IP) []string {
	for _, cidr := range prefixes {
		_, network, err := net.ParseCIDR(cidr)
		if err == nil && network.Contains(ip) {
			return prefixes
		}
	}
	// Synthesize /24 covering the LAN IP when no prefix was collected.
	mask := net.CIDRMask(24, 32)
	network := &net.IPNet{IP: ip.Mask(mask), Mask: mask}
	return append(prefixes, network.String())
}

func filterHomeNetworks(prefixes []string, tunnel *net.IPNet) []string {
	var out []string
	for _, cidr := range prefixes {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			continue
		}
		if tunnel != nil && (tunnel.Contains(network.IP) || network.Contains(tunnel.IP)) {
			continue
		}
		out = append(out, network.String())
	}
	return out
}

func sanitizeName(raw, fallback string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		raw = fallback
	}
	var b strings.Builder
	for _, r := range raw {
		if r < 0x20 || r == 0x7f {
			continue
		}
		b.WriteRune(r)
		if b.Len() >= 64 {
			break
		}
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		return fallback
	}
	if err := payload.ValidateName(out); err != nil {
		return fallback
	}
	return out
}
