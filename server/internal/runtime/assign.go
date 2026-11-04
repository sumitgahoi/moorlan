package runtime

import (
	"context"
	"fmt"
	"net"
	"sync"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/iface"
	"moorlan/internal/pair"
	"moorlan/internal/payload"
)

type wireguardClient interface {
	Device(string) (*wgtypes.Device, error)
	ConfigureDevice(string, wgtypes.Config) error
	Close() error
}
type Assigner struct {
	mu          sync.Mutex
	Host        Host
	store       *peerStore
	openClient  func() (wireguardClient, error)
	writeConfig func(string, []byte) error
}

// OpenAssigner repairs unfinished managed changes before any QR is displayed.
func OpenAssigner(ctx context.Context, host Host) (*Assigner, error) {
	config, err := readConfig(host.ConfPath)
	if err != nil {
		return nil, err
	}
	store, err := openStore(storePath(host.ConfPath), host.Snap.PublicKey, config)
	if err != nil {
		return nil, err
	}
	a := &Assigner{Host: host, store: store}
	if err = a.Reconcile(ctx); err != nil {
		a.Close()
		return nil, err
	}
	return a, nil
}
func (a *Assigner) Close() error { return a.store.db.Close() }
func (a *Assigner) client() (wireguardClient, error) {
	if a.openClient != nil {
		return a.openClient()
	}
	return wgctrl.New()
}
func (a *Assigner) Reconcile(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	client, err := a.client()
	if err != nil {
		return err
	}
	defer client.Close()
	return a.reconcile(ctx, client)
}
func (a *Assigner) reconcile(ctx context.Context, client wireguardClient) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	config, err := readConfig(a.Host.ConfPath)
	if err != nil {
		return err
	}
	peers, err := a.store.list(ctx)
	if err != nil {
		return err
	}
	removals, err := a.store.pending(ctx)
	if err != nil {
		return err
	}
	external := peerKeys(config.external)
	for _, p := range peers {
		if external[p.PublicKey] {
			return fmt.Errorf("managed peer also appears outside Moorlan block")
		}
	}
	for _, key := range removals {
		if external[key] {
			return fmt.Errorf("cannot remove a peer outside Moorlan block")
		}
	}
	// Database entries must still fit the configured tunnel subnet. Changing the
	// subnet behind Moorlan is unsupported; fail rather than send a bad lease.
	pool, err := iface.SelectPool(a.Host.Snap.Addresses)
	if err != nil {
		return err
	}
	for _, p := range peers {
		if !payload.ValidKey(p.PublicKey) {
			return fmt.Errorf("invalid stored peer key")
		}
		if _, err := iface.Allocate(pool, []iface.Peer{p}, p.PublicKey); err != nil {
			return err
		}
	}
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
	}
	if device.PublicKey.String() != a.Host.Snap.PublicKey {
		return fmt.Errorf("WireGuard server identity changed; restart Moorlan")
	}
	write := a.writeConfig
	if write == nil {
		write = writeConfig
	}
	if err = write(a.Host.ConfPath, config.render(peers)); err != nil {
		return fmt.Errorf("save managed block: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	// No ReplacePeers: unmanaged peers and their session/settings are untouched.
	for _, value := range removals {
		key, err := wgtypes.ParseKey(value)
		if err != nil {
			return err
		}
		if err = client.ConfigureDevice(device.Name, wgtypes.Config{Peers: []wgtypes.PeerConfig{{PublicKey: key, Remove: true}}}); err != nil {
			return fmt.Errorf("remove live peer: %w", err)
		}
	}
	for _, p := range peers {
		key, _ := wgtypes.ParseKey(p.PublicKey)
		_, network, _ := net.ParseCIDR(p.AllowedIPs[0])
		var existing *wgtypes.Peer
		for i := range device.Peers {
			if device.Peers[i].PublicKey == key {
				existing = &device.Peers[i]
				break
			}
		}
		allowed := []net.IPNet{*network}
		// Compare via CIDR strings so 4-byte vs 16-byte IPv4 forms from the
		// kernel and net.ParseCIDR do not force a needless ReplaceAllowedIPs.
		if existing != nil && sameAllowedIPs(existing.AllowedIPs, allowed) {
			continue
		}
		change := wgtypes.PeerConfig{PublicKey: key, AllowedIPs: allowed, ReplaceAllowedIPs: existing != nil}
		if err = client.ConfigureDevice(device.Name, wgtypes.Config{Peers: []wgtypes.PeerConfig{change}}); err != nil {
			return fmt.Errorf("install live peer: %w", err)
		}
	}
	_, err = a.store.db.ExecContext(ctx, "DELETE FROM pending_removals")
	return err
}
func peerKeys(peers []iface.Peer) map[string]bool {
	out := map[string]bool{}
	for _, p := range peers {
		out[p.PublicKey] = true
	}
	return out
}

func sameAllowedIPs(have, want []net.IPNet) bool {
	if len(have) != len(want) {
		return false
	}
	for i := range have {
		if have[i].String() != want[i].String() {
			return false
		}
	}
	return true
}

func (a *Assigner) Assign(ctx context.Context, publicKey, label string) (pair.Lease, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return pair.Lease{}, err
	}
	if err := payload.ValidateLabel(label); err != nil {
		return pair.Lease{}, err
	}
	label = payload.NormalizeLabel(label)
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return pair.Lease{}, err
	}
	publicKey = key.String()
	client, err := a.client()
	if err != nil {
		return pair.Lease{}, err
	}
	defer client.Close()
	// Finish a prior deletion before permitting this key (or its address) to be
	// enrolled again. Other failures leave the same assignment available on retry.
	pending, err := a.store.pending(ctx)
	if err != nil {
		return pair.Lease{}, err
	}
	if len(pending) != 0 {
		if err = a.reconcile(ctx, client); err != nil {
			return pair.Lease{}, err
		}
	}
	config, err := readConfig(a.Host.ConfPath)
	if err != nil {
		return pair.Lease{}, err
	}
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return pair.Lease{}, err
	}
	peers, err := a.store.list(ctx)
	if err != nil {
		return pair.Lease{}, err
	}
	managed := peerKeys(peers)
	if peerKeys(config.external)[publicKey] {
		return pair.Lease{}, fmt.Errorf("existing peer is outside Moorlan management")
	}
	for _, p := range device.Peers {
		if p.PublicKey == key && !managed[publicKey] {
			return pair.Lease{}, fmt.Errorf("existing live peer is outside Moorlan management")
		}
	}
	pool, err := iface.SelectPool(a.Host.Snap.Addresses)
	if err != nil {
		return pair.Lease{}, err
	}
	credential, err := unpairCredential(device.PrivateKey, key)
	if err != nil {
		return pair.Lease{}, err
	}
	address := ""
	for _, p := range peers {
		if p.PublicKey == publicKey {
			address = p.AllowedIPs[0]
		}
	}
	if address == "" {
		// Reserve the union of saved unmanaged routes, live routes, and committed
		// managed assignments. Duplicate observations of a route need no merging.
		reserved := append([]iface.Peer(nil), config.external...)
		reserved = append(reserved, devicePeers(device)...)
		reserved = append(reserved, peers...)
		ip, err := iface.Allocate(pool, reserved, publicKey)
		if err != nil {
			return pair.Lease{}, err
		}
		address = iface.AddressString(ip)
		if err = a.store.insert(ctx, publicKey, address, label); err != nil {
			return pair.Lease{}, fmt.Errorf("reserve address: %w", err)
		}
	} else if err = a.store.setLabel(ctx, publicKey, label); err != nil {
		return pair.Lease{}, fmt.Errorf("update device label: %w", err)
	}
	if err = a.reconcile(ctx, client); err != nil {
		return pair.Lease{}, err
	}
	return pair.Lease{Address: address, Prefixes: []string{pool.Network.String(), a.Host.LAN.CIDR}, LAN: a.Host.LAN.CIDR, PublicKey: device.PublicKey.String(), Endpoint: a.Host.Endpoint, MTU: a.Host.Snap.MTU, PersistentKeepalive: 25, UnpairToken: credential, Label: label}, nil
}
