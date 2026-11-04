package runtime

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
	path := filepath.Join(t.TempDir(), "wg0.conf")
	if err := os.WriteFile(path, []byte("[Interface]\nPrivateKey = original-secret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	fake := &fakeWG{device: &wgtypes.Device{Name: "wg0", PrivateKey: wgtypes.Key{3}, PublicKey: wgtypes.Key{2}, ListenPort: 51820}}
	config, err := readConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	store, err := openStore(path+".moorlan.db", fake.device.PublicKey.String(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.db.Close() })
	a := &Assigner{Host: Host{ConfPath: path, Snap: iface.Snapshot{Name: "wg0", PublicKey: fake.device.PublicKey.String(), Addresses: []string{"10.8.0.1/24"}, MTU: 1420}, HomeCIDRs: []string{"192.168.1.0/24"}, Endpoint: "vpn.example:51820"}, store: store, openClient: func() (wireguardClient, error) { return fake, nil }}
	peer, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	return a, fake, peer
}

// fixture returns a peer private key; WireGuard/Moorlan identify the peer by its public key.
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
	if len(rows) != 1 {
		t.Fatal(rows)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.Contains(string(raw), blockStart) || strings.Count(string(raw), peerPub(key)) != 1 || !strings.Contains(string(raw), "# phone\n") {
		t.Fatal(string(raw))
	}
	if rows[0].Label != "phone" {
		t.Fatal(rows[0].Label)
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
func TestRemoveManagedByPublicKeyAndUniqueLabel(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "iPhone 17"); err != nil {
		t.Fatal(err)
	}
	removed, err := a.RemoveManaged(context.Background(), "iPhone 17")
	if err != nil || removed != peerPub(key) {
		t.Fatalf("%q %v", removed, err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("admin removal incomplete")
	}

	first, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	second, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Assign(context.Background(), peerPub(first), "phone"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Assign(context.Background(), peerPub(second), "phone"); err != nil {
		t.Fatal(err)
	}
	if _, err := a.RemoveManaged(context.Background(), "phone"); err == nil {
		t.Fatal("ambiguous label accepted")
	}
	removed, err = a.RemoveManaged(context.Background(), peerPub(first))
	if err != nil || removed != peerPub(first) {
		t.Fatalf("%q %v", removed, err)
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
	// Explicit 16-byte IPv4 form (ParseIP) vs ParseCIDR's 4-byte form. On this
	// Go, those already DeepEqual-differ; String() must still match.
	sixteen := net.IPNet{IP: net.ParseIP("10.8.0.2"), Mask: net.CIDRMask(32, 32)}
	if reflect.DeepEqual(*parsed, sixteen) || parsed.String() != sixteen.String() {
		t.Fatalf("test setup broken: DeepEqual=%v parse=%q sixteen=%q lens=%d/%d",
			reflect.DeepEqual(*parsed, sixteen), parsed, sixteen, len(parsed.IP), len(sixteen.IP))
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

func TestSaveAndApplyFailuresKeepStableAssignment(t *testing.T) {
	for _, failure := range []string{"save", "apply"} {
		t.Run(failure, func(t *testing.T) {
			a, client, key := fixture(t)
			if failure == "save" {
				a.writeConfig = func(string, []byte) error { return errors.New("disk failed") }
			} else {
				client.configureErr = errors.New("device failed")
			}
			if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err == nil {
				t.Fatal("expected failure")
			}
			rows, err := a.store.list(context.Background())
			if err != nil || len(rows) != 1 || rows[0].AllowedIPs[0] != "10.8.0.2/32" {
				t.Fatalf("lost reservation: %v %v", rows, err)
			}
			if failure == "save" && len(client.changes) != 0 {
				t.Fatal("changed live state before saving")
			}
			a.writeConfig = nil
			client.configureErr = nil
			lease, err := a.Assign(context.Background(), peerPub(key), "phone")
			if err != nil || lease.Address != "10.8.0.2/32" {
				t.Fatalf("retry: %+v %v", lease, err)
			}
		})
	}
}
func TestRestartRepairsManagedBlockAndLiveState(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	// Both the block and live peer can be missing; the database retains intent.
	os.WriteFile(a.Host.ConfPath, []byte("[Interface]\n# keep this exactly\nPrivateKey = original-secret\n"), 0600)
	client.device.Peers = nil
	config, _ := readConfig(a.Host.ConfPath)
	store, err := openStore(a.Host.ConfPath+".moorlan.db", client.device.PublicKey.String(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	a.store = store
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.Contains(string(raw), peerPub(key)) || len(client.device.Peers) != 1 {
		t.Fatal("repair incomplete")
	}
}
func TestExistingPeersAndRangesAreNotManaged(t *testing.T) {
	a, client, key := fixture(t)
	other := wgtypes.Key{9}
	original := "[Interface]\nPrivateKey = original-secret\n\n[Peer]\n# administrator-owned\nPublicKey = " + other.String() + "\nAllowedIPs = 10.8.0.0/28\nPresharedKey = do-not-rewrite\n"
	os.WriteFile(a.Host.ConfPath, []byte(original), 0600)
	_, network, _ := net.ParseCIDR("10.8.0.0/28")
	client.device.Peers = []wgtypes.Peer{{PublicKey: other, AllowedIPs: []net.IPNet{*network}, PresharedKey: wgtypes.Key{7}}}
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil || lease.Address != "10.8.0.16/32" {
		t.Fatalf("%+v %v", lease, err)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.HasPrefix(string(raw), original) || client.device.Peers[0].PresharedKey != (wgtypes.Key{7}) {
		t.Fatal("unmanaged configuration changed")
	}
	if _, err := a.Assign(context.Background(), other.String(), "other"); err == nil {
		t.Fatal("took ownership of existing peer")
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
func TestDatabaseLossIsNotAnEmptyPeerList(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	config, _ := readConfig(a.Host.ConfPath)
	if _, err := openStore(filepath.Join(t.TempDir(), "missing.db"), client.device.PublicKey.String(), config); err == nil {
		t.Fatal("silently accepted lost database")
	}
}
func TestProcessLockRemainsHeldUntilReleased(t *testing.T) {
	a, _, _ := fixture(t)
	unlock, err := lockFile(a.Host.ConfPath + ".lock")
	if err != nil {
		t.Fatal(err)
	}
	if other, err := lockFile(a.Host.ConfPath + ".lock"); err == nil {
		other()
		t.Fatal("second lock succeeded")
	}
	unlock()
	unlock, err = lockFile(a.Host.ConfPath + ".lock")
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

func TestInterfaceLockRejectsUnsafeNames(t *testing.T) {
	for _, name := range []string{"", "../wg0", "/tmp/wg0", "wg 0", "abcdefghijklmnop"} {
		if validInterfaceName(name) {
			t.Fatalf("unsafe interface name %q", name)
		}
	}
	for _, name := range []string{"wg0", "home-wg", "wg_home.1"} {
		if !validInterfaceName(name) {
			t.Fatalf("valid name rejected: %s", name)
		}
	}
}

func TestAllocationReservesSavedLiveAndUnfinishedAssignments(t *testing.T) {
	a, client, key := fixture(t)
	saved, live, unfinished := wgtypes.Key{6}, wgtypes.Key{7}, wgtypes.Key{8}
	raw := "[Interface]\nPrivateKey = original-secret\n[Peer]\nPublicKey = " + saved.String() + "\nAllowedIPs = 10.8.0.2/32\n"
	if err := os.WriteFile(a.Host.ConfPath, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	_, network, _ := net.ParseCIDR("10.8.0.3/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: live, AllowedIPs: []net.IPNet{*network}}}
	// Represents a crash after assignment commit, before either save or apply.
	if err := a.store.insert(context.Background(), unfinished.String(), "10.8.0.4/32", "pending"); err != nil {
		t.Fatal(err)
	}
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil || lease.Address != "10.8.0.5/32" {
		t.Fatalf("%+v %v", lease, err)
	}
	// Reconciliation installs the unfinished managed peer, preserving live-only peers.
	found := map[wgtypes.Key]bool{}
	for _, p := range client.device.Peers {
		found[p.PublicKey] = true
	}
	if !found[live] || !found[unfinished] || !found[key.PublicKey()] {
		t.Fatal("unexpected live peer set")
	}
}
