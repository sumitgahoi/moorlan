package runtime

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"peerdoor/internal/iface"
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
	store, err := openStore(path+".peerdoor.db", fake.device.PublicKey.String(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.db.Close() })
	a := &Assigner{Host: Host{ConfPath: path, Snap: iface.Snapshot{Name: "wg0", PublicKey: fake.device.PublicKey.String(), Addresses: []string{"10.8.0.1/24"}, MTU: 1420}, LAN: iface.LAN{CIDR: "192.168.1.0/24"}, Endpoint: "vpn.example:51820"}, store: store, openClient: func() (wireguardClient, error) { return fake, nil }}
	return a, fake, wgtypes.Key{1}
}
func TestAssignPersistsAndRetriesWithoutChangingLivePeer(t *testing.T) {
	a, client, key := fixture(t)
	first, err := a.Assign(context.Background(), key.String())
	if err != nil {
		t.Fatal(err)
	}
	second, err := a.Assign(context.Background(), key.String())
	if err != nil {
		t.Fatal(err)
	}
	if first.Address != second.Address || first.UnjoinToken != second.UnjoinToken || first.Prefixes[0] != "10.8.0.0/24" {
		t.Fatalf("%+v %+v", first, second)
	}
	if len(client.changes) != 1 || client.changes[0].ReplacePeers {
		t.Fatal("retry changed existing sessions")
	}
	rows, _ := a.store.list(context.Background())
	if len(rows) != 1 {
		t.Fatal(rows)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.Contains(string(raw), blockStart) || strings.Count(string(raw), key.String()) != 1 {
		t.Fatal(string(raw))
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
			if _, err := a.Assign(context.Background(), key.String()); err == nil {
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
			lease, err := a.Assign(context.Background(), key.String())
			if err != nil || lease.Address != "10.8.0.2/32" {
				t.Fatalf("retry: %+v %v", lease, err)
			}
		})
	}
}
func TestRestartRepairsManagedBlockAndLiveState(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), key.String()); err != nil {
		t.Fatal(err)
	}
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	// Both the block and live peer can be missing; the database retains intent.
	os.WriteFile(a.Host.ConfPath, []byte("[Interface]\n# keep this exactly\nPrivateKey = original-secret\n"), 0600)
	client.device.Peers = nil
	config, _ := readConfig(a.Host.ConfPath)
	store, err := openStore(a.Host.ConfPath+".peerdoor.db", client.device.PublicKey.String(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	a.store = store
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.Contains(string(raw), key.String()) || len(client.device.Peers) != 1 {
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
	lease, err := a.Assign(context.Background(), key.String())
	if err != nil || lease.Address != "10.8.0.16/32" {
		t.Fatalf("%+v %v", lease, err)
	}
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if !strings.HasPrefix(string(raw), original) || client.device.Peers[0].PresharedKey != (wgtypes.Key{7}) {
		t.Fatal("unmanaged configuration changed")
	}
	if _, err := a.Assign(context.Background(), other.String()); err == nil {
		t.Fatal("took ownership of existing peer")
	}
}
func TestConcurrentAssignmentsAndDatabaseUniqueness(t *testing.T) {
	a, _, _ := fixture(t)
	results := make(chan string, 2)
	errs := make(chan error, 2)
	var done sync.WaitGroup
	for _, key := range []wgtypes.Key{{1}, {4}} {
		done.Add(1)
		go func(key wgtypes.Key) {
			defer done.Done()
			lease, err := a.Assign(context.Background(), key.String())
			if err != nil {
				errs <- err
				return
			}
			results <- lease.Address
		}(key)
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
	if err := a.store.insert(context.Background(), wgtypes.Key{5}.String(), first); err == nil {
		t.Fatal("database accepted duplicate address")
	}
}
func TestDatabaseLossIsNotAnEmptyPeerList(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), key.String()); err != nil {
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
	if err := a.store.insert(context.Background(), unfinished.String(), "10.8.0.4/32"); err != nil {
		t.Fatal(err)
	}
	lease, err := a.Assign(context.Background(), key.String())
	if err != nil || lease.Address != "10.8.0.5/32" {
		t.Fatalf("%+v %v", lease, err)
	}
	// Reconciliation installs the unfinished managed peer, preserving live-only peers.
	found := map[wgtypes.Key]bool{}
	for _, p := range client.device.Peers {
		found[p.PublicKey] = true
	}
	if !found[live] || !found[unfinished] || !found[key] {
		t.Fatal("unexpected live peer set")
	}
}
