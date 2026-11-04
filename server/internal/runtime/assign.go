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
	mu         sync.Mutex
	Host       Host
	store      *peerStore
	openClient func() (wireguardClient, error)
}

// OpenAssigner opens the peer database. It does not touch the live device;
// call Reconcile (rehydrate) or mutate via Assign/Remove to apply peers.
func OpenAssigner(ctx context.Context, host Host) (*Assigner, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	store, err := openStore(host.StorePath, host.Snap.PublicKey)
	if err != nil {
		return nil, err
	}
	return &Assigner{Host: host, store: store}, nil
}

// InitDatabase creates a database for an empty device without changing live peers.
// The caller holds the interface lock, just as for all other command modes.
func InitDatabase(ctx context.Context, host Host) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	live, err := countLivePeers(host.Snap.Name)
	if err != nil {
		return err
	}
	return initStore(host.StorePath, host.Snap.PublicKey, live)
}

func countLivePeers(name string) (int, error) {
	client, err := wgctrl.New()
	if err != nil {
		return 0, err
	}
	defer client.Close()
	device, err := client.Device(name)
	if err != nil {
		return 0, err
	}
	return len(device.Peers), nil
}

func (a *Assigner) Close() error { return a.store.db.Close() }

func (a *Assigner) client() (wireguardClient, error) {
	if a.openClient != nil {
		return a.openClient()
	}
	return wgctrl.New()
}

// Reconcile applies SQLite to the live device: pending removals, install DB
// peers, drop orphans (moorlanN is exclusively owned by Moorlan).
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
	peers, err := a.store.list(ctx)
	if err != nil {
		return err
	}
	removals, err := a.store.pending(ctx)
	if err != nil {
		return err
	}
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, value := range removals {
		key, err := wgtypes.ParseKey(value)
		if err != nil {
			return err
		}
		if err = client.ConfigureDevice(device.Name, wgtypes.Config{Peers: []wgtypes.PeerConfig{{PublicKey: key, Remove: true}}}); err != nil {
			return fmt.Errorf("remove live peer: %w", err)
		}
	}
	managed := peerKeys(peers)
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
		if existing != nil && sameAllowedIPs(existing.AllowedIPs, allowed) {
			continue
		}
		change := wgtypes.PeerConfig{PublicKey: key, AllowedIPs: allowed, ReplaceAllowedIPs: existing != nil}
		if err = client.ConfigureDevice(device.Name, wgtypes.Config{Peers: []wgtypes.PeerConfig{change}}); err != nil {
			return fmt.Errorf("install live peer: %w", err)
		}
	}
	// Refresh after installs so orphan detection sees current state.
	device, err = client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
	}
	for _, live := range device.Peers {
		if managed[live.PublicKey.String()] {
			continue
		}
		if err = client.ConfigureDevice(device.Name, wgtypes.Config{Peers: []wgtypes.PeerConfig{{PublicKey: live.PublicKey, Remove: true}}}); err != nil {
			return fmt.Errorf("remove orphan live peer: %w", err)
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
	pending, err := a.store.pending(ctx)
	if err != nil {
		return pair.Lease{}, err
	}
	if len(pending) != 0 {
		if err = a.reconcile(ctx, client); err != nil {
			return pair.Lease{}, err
		}
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
	for _, p := range device.Peers {
		if p.PublicKey == key && !managed[publicKey] {
			return pair.Lease{}, fmt.Errorf("existing live peer is not in the Moorlan database; run --rehydrate or remove it first")
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
		reserved := append([]iface.Peer(nil), devicePeers(device)...)
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
	return pair.Lease{Address: address, Prefixes: a.Host.RoutePrefixes(pool.Network.String()), LAN: a.Host.HomeCIDRLease(), PublicKey: device.PublicKey.String(), Endpoint: a.Host.Endpoint, MTU: a.Host.Snap.MTU, PersistentKeepalive: 25, UnpairToken: credential, Label: label}, nil
}
