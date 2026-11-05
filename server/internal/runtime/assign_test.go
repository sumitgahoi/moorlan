package runtime

import (
	"context"
	"errors"
	"net"
	"path/filepath"
	"reflect"
	"sync"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/iface"
)

type fakeWG struct {
	device       *wgtypes.Device
	changes      []wgtypes.Config
	configureErr error
}

func (f *fakeWG) Device(string) (*wgtypes.Device, error) { return f.device, nil }
func (f *fakeWG) Close() error                           { return nil }
func (f *fakeWG) ConfigureDevice(_ string, c wgtypes.Config) error {
	f.changes = append(f.changes, c)
	if f.configureErr != nil {
		return f.configureErr
	}
	for _, change := range c.Peers {
		found := -1
		for i, p := range f.device.Peers {
			if p.PublicKey == change.PublicKey {
				found = i
				break
			}
		}
		if change.Remove {
			if found >= 0 {
				f.device.Peers = append(f.device.Peers[:found], f.device.Peers[found+1:]...)
			}
			continue
		}
		if found < 0 {
			f.device.Peers = append(f.device.Peers, wgtypes.Peer{PublicKey: change.PublicKey})
			found = len(f.device.Peers) - 1
		}
		f.device.Peers[found].AllowedIPs = change.AllowedIPs
	}
	return nil
}

func fixture(t *testing.T) (*Assigner, *fakeWG, wgtypes.Key) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "moorlan0.db")
	fake := &fakeWG{device: &wgtypes.Device{Name: "moorlan0", PrivateKey: wgtypes.Key{3}, PublicKey: wgtypes.Key{2}, ListenPort: 51823}}
	if err := initStore(dbPath, fake.device.PublicKey.String(), 0); err != nil {
		t.Fatal(err)
	}
	store, err := openStore(dbPath, fake.device.PublicKey.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.db.Close() })
	a := &Assigner{
		Host: Host{
			StorePath: dbPath,
			Snap:      iface.Snapshot{Name: "moorlan0", PublicKey: fake.device.PublicKey.String(), Addresses: []string{"10.8.0.1/24"}, MTU: 1420},
			HomeCIDRs: []string{"192.168.1.0/24"},
			Endpoint:  "vpn.example:51823",
		},
		store:      store,
		openClient: func() (wireguardClient, error) { return fake, nil },
	}
	peer, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	return a, fake, peer
}

func peerPub(private wgtypes.Key) string { return private.PublicKey().String() }

func TestAssignPersistsAndRetriesWithoutChangingLivePeer(t *testing.T) {
	a, client, key := fixture(t)
	first, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	second, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	if first.Address != second.Address || first.UnpairToken != second.UnpairToken || first.Prefixes[0] != "10.8.0.0/24" {
		t.Fatalf("%+v %+v", first, second)
	}
	if len(first.UnpairToken) != 64 {
		t.Fatal("expected plaintext HMAC credential")
	}
	if len(client.changes) != 1 || client.changes[0].ReplacePeers {
		t.Fatal("retry changed existing sessions")
	}
	rows, _ := a.store.list(context.Background())
	if len(rows) != 1 || rows[0].Label != "phone" {
		t.Fatal(rows)
	}
}

func TestAssignAllowsDuplicateLabels(t *testing.T) {
	a, _, key := fixture(t)
	first, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil || first.Label != "phone" {
		t.Fatalf("%+v %v", first, err)
	}
	other, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	second, err := a.Assign(context.Background(), peerPub(other), "phone")
	if err != nil || second.Label != "phone" {
		t.Fatalf("%+v %v", second, err)
	}
}

func TestRemoveManagedByPublicKeyOnly(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "iPhone 17"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.RemoveManaged(context.Background(), "iPhone 17"); err == nil {
		t.Fatal("label removal accepted")
	}
	removed, err := a.RemoveManaged(context.Background(), peerPub(key))
	if err != nil || removed != peerPub(key) {
		t.Fatalf("%q %v", removed, err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("admin removal incomplete")
	}
}

func TestReconcileSkipsPeerWhenAllowedIPsOnlyDifferByEncoding(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	_, parsed, err := net.ParseCIDR("10.8.0.2/32")
	if err != nil {
		t.Fatal(err)
	}
	sixteen := net.IPNet{IP: net.ParseIP("10.8.0.2"), Mask: net.CIDRMask(32, 32)}
	if reflect.DeepEqual(*parsed, sixteen) || parsed.String() != sixteen.String() {
		t.Fatalf("test setup broken: DeepEqual=%v parse=%q sixteen=%q",
			reflect.DeepEqual(*parsed, sixteen), parsed, sixteen)
	}
	client.device.Peers[0].AllowedIPs = []net.IPNet{sixteen}
	before := len(client.changes)
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(client.changes) != before {
		t.Fatal("reconfigured peer whose AllowedIPs only differed by IP encoding")
	}
}

func TestApplyFailureKeepsStableAssignment(t *testing.T) {
	a, client, key := fixture(t)
	client.configureErr = errors.New("device failed")
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err == nil {
		t.Fatal("expected failure")
	}
	rows, err := a.store.list(context.Background())
	if err != nil || len(rows) != 1 || rows[0].AllowedIPs[0] != "10.8.0.2/32" {
		t.Fatalf("lost reservation: %v %v", rows, err)
	}
	client.configureErr = nil
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil || lease.Address != "10.8.0.2/32" {
		t.Fatalf("retry: %+v %v", lease, err)
	}
}

func TestRehydrateRestoresMissingLivePeers(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	client.device.Peers = nil
	client.changes = nil
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 1 {
		t.Fatal("rehydrate incomplete")
	}
}

func TestRehydrateRemovesOrphanLivePeers(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	orphan := wgtypes.Key{9}
	_, network, _ := net.ParseCIDR("10.8.0.99/32")
	client.device.Peers = append(client.device.Peers, wgtypes.Peer{PublicKey: orphan, AllowedIPs: []net.IPNet{*network}})
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 1 || client.device.Peers[0].PublicKey != key.PublicKey() {
		t.Fatalf("orphan not removed: %+v", client.device.Peers)
	}
}

func TestAssignRefusesUnmanagedLivePeer(t *testing.T) {
	a, client, key := fixture(t)
	_, network, _ := net.ParseCIDR("10.8.0.2/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: key.PublicKey(), AllowedIPs: []net.IPNet{*network}}}
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err == nil {
		t.Fatal("took ownership of unmanaged live peer")
	}
}

func TestConcurrentAssignmentsAndDatabaseUniqueness(t *testing.T) {
	a, _, _ := fixture(t)
	results := make(chan string, 2)
	errs := make(chan error, 2)
	var done sync.WaitGroup
	peers := make([]wgtypes.Key, 2)
	for i := range peers {
		var err error
		peers[i], err = wgtypes.GeneratePrivateKey()
		if err != nil {
			t.Fatal(err)
		}
	}
	for i, key := range peers {
		done.Add(1)
		go func(i int, key wgtypes.Key) {
			defer done.Done()
			lease, err := a.Assign(context.Background(), peerPub(key), "phone-"+string(rune('a'+i)))
			if err != nil {
				errs <- err
				return
			}
			results <- lease.Address
		}(i, key)
	}
	done.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	first, second := <-results, <-results
	if first == second {
		t.Fatal("duplicate address")
	}
	if err := a.store.insert(context.Background(), wgtypes.Key{5}.String(), first, "other"); err == nil {
		t.Fatal("database accepted duplicate address")
	}
}

func TestProcessLockRemainsHeldUntilReleased(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock")
	unlock, err := lockFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if other, err := lockFile(path); err == nil {
		other()
		t.Fatal("second lock succeeded")
	}
	unlock()
	unlock, err = lockFile(path)
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

func TestInterfaceNameValidation(t *testing.T) {
	for _, name := range []string{"", "1wg", "../wg0", "wg/0", "a.b", "thisnameiswaytoolong01"} {
		if validInterfaceName(name) {
			t.Fatalf("unsafe interface name %q", name)
		}
	}
	for _, name := range []string{"wg0", "wg1", "moorlan0", "home-wg"} {
		if !validInterfaceName(name) {
			t.Fatalf("valid name rejected: %s", name)
		}
	}
}

func TestAllocationReservesLiveAndUnfinishedAssignments(t *testing.T) {
	a, client, key := fixture(t)
	live, unfinished := wgtypes.Key{7}, wgtypes.Key{8}
	_, network, _ := net.ParseCIDR("10.8.0.3/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: live, AllowedIPs: []net.IPNet{*network}}}
	if err := a.store.insert(context.Background(), unfinished.String(), "10.8.0.4/32", "pending"); err != nil {
		t.Fatal(err)
	}
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil || lease.Address != "10.8.0.2/32" {
		// .2 free, .3 live orphan reserved, .4 unfinished in DB; but reconcile removes orphan live!
		// Order: insert new peer, then reconcile which removes orphan `live` and installs unfinished+new.
		// Occupied at alloc time includes live .3 and unfinished .4, so new gets .2.
		t.Fatalf("%+v %v", lease, err)
	}
	found := map[wgtypes.Key]bool{}
	for _, p := range client.device.Peers {
		found[p.PublicKey] = true
	}
	// Orphan live peer is removed on reconcile; unfinished + new remain.
	if found[live] || !found[unfinished] || !found[key.PublicKey()] {
		t.Fatalf("unexpected live peer set: %v", found)
	}
}
