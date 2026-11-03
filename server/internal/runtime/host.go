package runtime

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"peerdoor/internal/iface"
)

type Host struct {
	Snap     iface.Snapshot
	LAN      iface.LAN
	ConfPath string
	PairHost string
	PairPort int
	Endpoint string
}

func Discover(name, confPath, lanIface, endpoint string, pairPort int) (Host, error) {
	return discover(name, confPath, lanIface, endpoint, pairPort, true)
}

// DiscoverUnjoin needs only the existing device, LAN, and save configuration.
func DiscoverUnjoin(name, confPath, lanIface string, port int) (Host, error) {
	return discover(name, confPath, lanIface, "", port, false)
}

func discover(name, confPath, lanIface, endpoint string, pairPort int, pairing bool) (Host, error) {
	if runtime.GOOS != "linux" {
		return Host{}, fmt.Errorf("PeerDoor server requires Linux")
	}
	if !validInterfaceName(name) {
		return Host{}, fmt.Errorf("invalid WireGuard interface name")
	}
	client, err := wgctrl.New()
	if err != nil {
		return Host{}, err
	}
	defer client.Close()
	device, err := client.Device(name)
	if err != nil {
		return Host{}, fmt.Errorf("read WireGuard interface %s: %w", name, err)
	}
	addrs, mtu, err := interfaceAddresses(name)
	if err != nil {
		return Host{}, err
	}
	lan, err := discoverLAN(name, lanIface)
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
	if err := validateLAN(lan, subnet); err != nil {
		return Host{}, err
	}
	if pairPort < 1 || pairPort > 65535 {
		return Host{}, fmt.Errorf("invalid pairing port %d", pairPort)
	}
	if err := validateInterface(device, addrs, pairing); err != nil {
		return Host{}, err
	}
	if confPath == "" {
		confPath = filepath.Join("/etc/wireguard", name+".conf")
	}
	confPath, err = filepath.Abs(confPath)
	if err != nil {
		return Host{}, err
	}
	if filepath.Base(confPath) != name+".conf" {
		return Host{}, fmt.Errorf("wg-quick config filename must be %s.conf", name)
	}
	info, err := os.Lstat(confPath)
	if err != nil {
		return Host{}, err
	}
	if !info.Mode().IsRegular() {
		return Host{}, fmt.Errorf("unsupported config: use a regular wg-quick file, not a symlink")
	}
	if _, err := os.ReadFile(confPath); err != nil {
		return Host{}, fmt.Errorf("read wg-quick configuration: %w", err)
	}
	return Host{
		Snap: iface.Snapshot{
			Name:       name,
			PublicKey:  device.PublicKey.String(),
			ListenPort: device.ListenPort,
			MTU:        mtu,
			Addresses:  addrs,
		},
		LAN:      lan,
		ConfPath: confPath,
		PairHost: lan.IP,
		PairPort: pairPort,
		Endpoint: endpoint,
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

// Connecting a UDP socket asks the OS for the source address it would route
// toward the Internet. No packets are sent. Match it to an interface to obtain
// the LAN prefix, rather than confusing Docker bridges with the default NIC.
func outboundIPv4() (net.IP, error) {
	conn, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(1, 1, 1, 1), Port: 53})
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP, nil
}

func discoverLAN(wgName, lanIface string) (iface.LAN, error) {
	source, err := outboundIPv4()
	if err != nil && lanIface == "" {
		return iface.LAN{}, fmt.Errorf("cannot determine LAN route: %w; use -lan-iface", err)
	}
	devices, err := net.Interfaces()
	if err != nil {
		return iface.LAN{}, err
	}
	var candidates []iface.LAN
	for _, device := range devices {
		if device.Name == wgName || device.Flags&net.FlagUp == 0 || device.Flags&net.FlagLoopback != 0 {
			continue
		}
		if lanIface != "" && device.Name != lanIface {
			continue
		}
		addresses, err := device.Addrs()
		if err != nil {
			return iface.LAN{}, err
		}
		for _, address := range addresses {
			ip, network, err := net.ParseCIDR(address.String())
			if err != nil || ip.To4() == nil || !ip.IsGlobalUnicast() {
				continue
			}
			candidates = append(candidates, iface.LAN{Device: device.Name, IP: ip.String(), CIDR: network.String()})
		}
	}
	return selectLAN(candidates, lanIface, source)
}

func selectLAN(candidates []iface.LAN, lanIface string, source net.IP) (iface.LAN, error) {
	var eligible []iface.LAN
	for _, candidate := range candidates {
		if lanIface != "" && candidate.Device != lanIface {
			continue
		}
		eligible = append(eligible, candidate)
	}
	for _, candidate := range eligible {
		if net.ParseIP(candidate.IP).Equal(source) {
			return candidate, nil
		}
	}
	if lanIface != "" && len(eligible) == 1 {
		return eligible[0], nil
	}
	return iface.LAN{}, fmt.Errorf("cannot select a LAN IPv4 address from the Internet route; use -lan-iface to select an interface")
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

func validateLAN(lan iface.LAN, tunnel *net.IPNet) error {
	ip := net.ParseIP(lan.IP)
	_, network, err := net.ParseCIDR(lan.CIDR)
	if ip.To4() == nil || !ip.IsPrivate() || err != nil || !network.Contains(ip) || !network.IP.IsPrivate() {
		return fmt.Errorf("unsupported LAN: use a private home IPv4 network")
	}
	if tunnel != nil && (tunnel.Contains(network.IP) || network.Contains(tunnel.IP)) {
		return fmt.Errorf("unsupported setup: WireGuard subnet and home LAN must not overlap")
	}
	return nil
}
