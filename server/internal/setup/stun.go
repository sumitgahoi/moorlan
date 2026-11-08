package setup

import (
	"fmt"
	"net"
	"time"

	"github.com/pion/stun/v2"
)

// DefaultSTUNServers are public STUN endpoints used to guess a public IP.
var DefaultSTUNServers = []string{
	"stun.l.google.com:19302",
	"stun.cloudflare.com:3478",
}

// StunPublicIP queries STUN servers over an ephemeral UDP socket and returns
// the mapped public IPv4. The WireGuard listen port is applied separately
// (userspace cannot usually bind the same port as the kernel WG socket).
func StunPublicIP(servers []string) (net.IP, error) {
	if len(servers) == 0 {
		servers = DefaultSTUNServers
	}
	var last error
	for _, server := range servers {
		ip, err := stunOnce(server)
		if err != nil {
			last = err
			continue
		}
		if ip4 := ip.To4(); ip4 != nil && !ip4.IsPrivate() && !ip4.IsLoopback() && !ip4.IsUnspecified() {
			return ip4, nil
		}
		last = fmt.Errorf("STUN %s returned non-public %v", server, ip)
	}
	if last == nil {
		last = fmt.Errorf("no STUN servers")
	}
	return nil, last
}

func stunOnce(server string) (net.IP, error) {
	conn, err := net.DialTimeout("udp4", server, 3*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	client, err := stun.NewClient(conn)
	if err != nil {
		return nil, err
	}
	defer client.Close()

	var xorAddr stun.XORMappedAddress
	message := stun.MustBuild(stun.TransactionID, stun.BindingRequest)
	if err := client.Do(message, func(res stun.Event) {
		if res.Error != nil {
			err = res.Error
			return
		}
		err = xorAddr.GetFrom(res.Message)
	}); err != nil {
		return nil, err
	}
	if err != nil {
		return nil, err
	}
	return xorAddr.IP, nil
}
