package iface

// Peer describes the addresses associated with a WireGuard public key.
type Peer struct {
	PublicKey  string
	AllowedIPs []string
	Label      string
}

// Snapshot contains only public interface information.
type Snapshot struct {
	PublicKey  string
	Name       string
	ListenPort int
	MTU        int
	Addresses  []string
}

// LAN is the local interface/address used for pairing and its network.
type LAN struct {
	Device string
	IP     string
	CIDR   string
}
