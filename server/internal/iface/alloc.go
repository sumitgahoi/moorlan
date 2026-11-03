package iface

import (
	"encoding/binary"
	"fmt"
	"net"
)

// Pool is inferred from one private IPv4 interface address. Bounds keep the
// allocation scan small; /24 is the usual home-server setup.
type Pool struct {
	Network *net.IPNet
	Own     net.IP
}

func SelectPool(addresses []string) (Pool, error) {
	var pool Pool
	for _, address := range addresses {
		ip, network, err := net.ParseCIDR(address)
		if err != nil {
			return Pool{}, fmt.Errorf("invalid interface address %q", address)
		}
		if ip.To4() == nil {
			continue
		} // Existing IPv6 configuration is not managed.
		if pool.Network != nil {
			return Pool{}, fmt.Errorf("unsupported setup: WireGuard must have exactly one IPv4 address")
		}
		prefix, _ := network.Mask.Size()
		if !ip.IsPrivate() || prefix < 16 || prefix > 30 {
			return Pool{}, fmt.Errorf("unsupported setup: use one private IPv4 subnet with a /16 through /30 prefix, such as 10.8.0.1/24")
		}
		pool = Pool{Network: network, Own: ip.To4()}
	}
	if pool.Network == nil {
		return Pool{}, fmt.Errorf("unsupported setup: WireGuard needs one private IPv4 subnet, such as 10.8.0.1/24")
	}
	first, last := pool.bounds()
	own := ipv4Num(pool.Own)
	if own < first || own > last {
		return Pool{}, fmt.Errorf("server address is the subnet's network or broadcast address")
	}
	return pool, nil
}

func (p Pool) bounds() (uint32, uint32) {
	prefix, _ := p.Network.Mask.Size()
	base := ipv4Num(p.Network.IP)
	size := uint32(1) << uint(32-prefix)
	return base + 1, base + size - 2
}

// Occupied reserves addresses covered by existing routes. Scans are bounded by
// the supported tunnel pool, even when a peer advertises a much larger subnet.
func Occupied(pool Pool, peers []Peer) (map[uint32]bool, error) {
	if pool.Network == nil || pool.Own.To4() == nil {
		return nil, fmt.Errorf("missing device subnet")
	}
	prefix, bits := pool.Network.Mask.Size()
	if bits != 32 || prefix < 16 || prefix > 30 {
		return nil, fmt.Errorf("unsupported device subnet prefix")
	}
	first, last := pool.bounds()
	used := map[uint32]bool{ipv4Num(pool.Own): true}
	for _, peer := range peers {
		for _, allowed := range peer.AllowedIPs {
			ip, network, err := net.ParseCIDR(allowed)
			if err != nil {
				return nil, fmt.Errorf("invalid peer address %q", allowed)
			}
			if ip.To4() == nil {
				continue
			}
			if !pool.Network.Contains(network.IP) && !network.Contains(pool.Network.IP) {
				continue
			}
			prefix, _ := network.Mask.Size()
			if prefix != 32 {
				for n := first; n <= last; n++ {
					if network.Contains(numIPv4(n)) {
						used[n] = true
					}
				}
				continue
			}
			n := ipv4Num(ip)
			if n < first || n > last {
				return nil, fmt.Errorf("peer uses reserved address %s", ip)
			}
			if ip.Equal(pool.Own) {
				return nil, fmt.Errorf("address %s belongs to the server", ip)
			}
			used[n] = true
		}
	}
	return used, nil
}

func Allocate(pool Pool, peers []Peer, publicKey string) (net.IP, error) {
	used, err := Occupied(pool, peers)
	if err != nil {
		return nil, err
	}
	for _, peer := range peers {
		if peer.PublicKey != publicKey {
			continue
		}
		if len(peer.AllowedIPs) != 1 {
			return nil, fmt.Errorf("unsupported existing peer: expected a single IPv4 /32 device address")
		}
		ip, network, err := net.ParseCIDR(peer.AllowedIPs[0])
		if err != nil || ip.To4() == nil || !pool.Network.Contains(ip) {
			return nil, fmt.Errorf("existing peer is outside the device subnet")
		}
		prefix, _ := network.Mask.Size()
		if prefix != 32 {
			return nil, fmt.Errorf("existing peer is not an individual /32 device")
		}
		return ip.To4(), nil
	}
	first, last := pool.bounds()
	for n := first; n <= last; n++ {
		if !used[n] {
			return numIPv4(n), nil
		}
	}
	return nil, fmt.Errorf("no free device address in %s", pool.Network)
}
func ipv4Num(ip net.IP) uint32       { return binary.BigEndian.Uint32(ip.To4()) }
func numIPv4(n uint32) net.IP        { ip := make(net.IP, 4); binary.BigEndian.PutUint32(ip, n); return ip }
func AddressString(ip net.IP) string { return ip.To4().String() + "/32" }
