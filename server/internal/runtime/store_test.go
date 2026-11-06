package runtime

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func TestOpenStoreCreatesHostDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing", "moorlan.db")
	store, err := openStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("database permissions: %v %v", info, err)
	}
	if peers, err := store.list(context.Background(), "wg0"); err != nil || len(peers) != 0 {
		t.Fatalf("initialized peers: %v %v", peers, err)
	}
}

func TestBindInterfaceIsSticky(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moorlan.db")
	store, err := openStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	ctx := context.Background()
	key := wgtypes.Key{2}.String()
	if err := store.bindInterface(ctx, "wg0", key); err != nil {
		t.Fatal(err)
	}
	if err := store.bindInterface(ctx, "wg0", key); err != nil {
		t.Fatal(err)
	}
	if err := store.bindInterface(ctx, "wg0", wgtypes.Key{9}.String()); err == nil {
		t.Fatal("accepted a different server identity")
	}
	if err := store.bindInterface(ctx, "wg1", wgtypes.Key{3}.String()); err != nil {
		t.Fatal(err)
	}
	names, err := store.interfaceNames(ctx)
	if err != nil || len(names) != 2 || names[0] != "wg0" || names[1] != "wg1" {
		t.Fatalf("%v %v", names, err)
	}
}

func TestInitializedStorePreservesIdentityAndAssignments(t *testing.T) {
	a, client, key := fixture(t)
	ctx := context.Background()
	lease, err := a.Assign(ctx, peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	store, err := openStore(a.Host.StorePath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	if err := store.bindInterface(ctx, "moorlan0", wgtypes.Key{9}.String()); err == nil {
		t.Fatal("accepted a different server identity")
	}
	if err := store.bindInterface(ctx, "moorlan0", client.device.PublicKey.String()); err != nil {
		t.Fatal(err)
	}
	peer, err := store.lookupPublicKey(ctx, "moorlan0", peerPub(key))
	if err != nil || peer.AllowedIPs[0] != lease.Address || peer.Label != "phone" {
		t.Fatalf("assignment lost: %+v %v", peer, err)
	}
}

func TestOpenAssignerRecreatesMissingDatabase(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "phone"); err != nil {
		t.Fatal(err)
	}
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(a.Host.StorePath); err != nil {
		t.Fatal(err)
	}
	// Host-wide DB is created on demand; live peers are untouched until reconcile.
	opened, err := OpenAssigner(context.Background(), a.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	if _, err := os.Stat(a.Host.StorePath); err != nil {
		t.Fatalf("database was not created: %v", err)
	}
	if len(client.device.Peers) != 1 || client.device.Peers[0].PublicKey != key.PublicKey() {
		t.Fatal("live peer changed")
	}
	// Fresh DB has no peer rows for this iface yet — reconcile would clear live.
	peers, err := opened.List(context.Background())
	if err != nil || len(peers) != 0 {
		t.Fatalf("expected empty recreated DB peers: %v %v", peers, err)
	}
}

func TestReconcileTargetsUnionAndFilter(t *testing.T) {
	got, err := ReconcileTargets([]string{"wg1", "wg0"}, []string{"wg0", "wg2"}, "")
	if err != nil || strings.Join(got, ",") != "wg0,wg1,wg2" {
		t.Fatalf("%v %v", got, err)
	}
	got, err = ReconcileTargets([]string{"wg0"}, []string{"wg2"}, "wg2")
	if err != nil || len(got) != 1 || got[0] != "wg2" {
		t.Fatalf("%v %v", got, err)
	}
	if _, err := ReconcileTargets([]string{"wg0"}, nil, "wg9"); err == nil {
		t.Fatal("unknown filter accepted")
	}
}

func TestSamePeerKeyAllowedOnTwoInterfaces(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moorlan.db")
	store, err := openStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	ctx := context.Background()
	key := wgtypes.Key{5}.String()
	if err := store.bindInterface(ctx, "wg0", wgtypes.Key{1}.String()); err != nil {
		t.Fatal(err)
	}
	if err := store.bindInterface(ctx, "wg1", wgtypes.Key{2}.String()); err != nil {
		t.Fatal(err)
	}
	if err := store.insert(ctx, "wg0", key, "10.8.0.2/32", "phone"); err != nil {
		t.Fatal(err)
	}
	if err := store.insert(ctx, "wg1", key, "10.9.0.2/32", "phone"); err != nil {
		t.Fatal(err)
	}
	all, err := store.listAll(ctx, "")
	if err != nil || len(all) != 2 {
		t.Fatalf("%v %v", all, err)
	}
}
