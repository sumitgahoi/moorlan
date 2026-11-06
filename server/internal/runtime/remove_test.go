package runtime

import (
	"context"
	"errors"
	"net"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/pair"
)

func TestUnpairCredentialIsStableAndPeerSpecific(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	expected, _ := unpairCredential(client.device.PrivateKey, key.PublicKey())
	other, _ := unpairCredential(client.device.PrivateKey, wgtypes.Key{8})
	rotated, _ := unpairCredential(wgtypes.Key{9}, key.PublicKey())
	if expected != lease.UnpairToken || len(expected) != 64 || other == expected || rotated == expected {
		t.Fatal("invalid credential")
	}
}

func TestUnpairDeletesRecordAndIsIdempotent(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err != nil {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	rows, _ := a.store.list(context.Background(), "moorlan0")
	if len(rows) != 0 || len(client.device.Peers) != 0 {
		t.Fatal("removal incomplete")
	}
	nextKey, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	next, err := a.Assign(context.Background(), peerPub(nextKey), "phone")
	if err != nil || next.Address != lease.Address {
		t.Fatalf("%+v %v", next, err)
	}
}

func TestUnpairSucceedsWhenReconcileFailsAfterDBDelete(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	client.configureErr = errors.New("device failure")
	if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err != nil {
		t.Fatalf("DB-won remove must succeed even if reconcile fails: %v", err)
	}
	rows, _ := a.store.list(context.Background(), "moorlan0")
	if len(rows) != 0 {
		t.Fatal("DB should already have deleted the peer")
	}
	if len(client.device.Peers) != 1 {
		t.Fatal("live peer should remain until reconcile succeeds")
	}
	a.store.db.Close()
	store, err := openStore(a.Host.StorePath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	if err := store.bindInterface(context.Background(), "moorlan0", client.device.PublicKey.String()); err != nil {
		t.Fatal(err)
	}
	a.store = store
	client.configureErr = nil
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("removed peer resurrected")
	}
}

func TestWrongUnpairCredentialDoesNotMutate(t *testing.T) {
	a, client, key := fixture(t)
	if err := a.Remove(context.Background(), peerPub(key), "wrong"); !errors.Is(err, pair.ErrUnauthorized) {
		t.Fatal(err)
	}
	if len(client.changes) != 0 {
		t.Fatal("unauthorized mutation")
	}
}

func TestUnpairRetryClearsLiveOrphanAfterDBWon(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	client.configureErr = errors.New("device failure")
	if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 1 {
		t.Fatal("expected live orphan after failed reconcile")
	}
	client.configureErr = nil
	if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("live orphan not cleared on retry")
	}
}

func TestUnpairOfNeverEnrolledKeyIsIdempotentSuccess(t *testing.T) {
	a, client, key := fixture(t)
	credential, _ := unpairCredential(client.device.PrivateKey, key.PublicKey())
	if err := a.Remove(context.Background(), peerPub(key), credential); err != nil {
		t.Fatal(err)
	}
	if len(client.changes) != 0 {
		t.Fatal("absent peer mutated live state")
	}
}

func TestAdminRemoveSucceedsWhenReconcileFailsAfterDBDelete(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "Kitchen iPhone"); err != nil {
		t.Fatal(err)
	}
	client.configureErr = errors.New("device failure")
	removed, err := a.RemoveManaged(context.Background(), peerPub(key))
	if err != nil || removed != peerPub(key) {
		t.Fatalf("DB-won admin remove must succeed: %q %v", removed, err)
	}
	if len(client.device.Peers) != 1 {
		t.Fatal("peer should still be live after failed apply")
	}
	client.configureErr = nil
	removed, err = a.RemoveManaged(context.Background(), peerPub(key))
	if err != nil || removed != peerPub(key) {
		t.Fatalf("orphan retry: %q %v", removed, err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("live orphan not cleared on key retry")
	}
}

func TestAdminRemoveRejectsNeverEnrolledKey(t *testing.T) {
	a, _, key := fixture(t)
	if _, err := a.RemoveManaged(context.Background(), peerPub(key)); err == nil {
		t.Fatal("never-enrolled admin remove accepted")
	}
}

func TestReconcileClearsOrphanWithoutPendingJournal(t *testing.T) {
	a, client, key := fixture(t)
	_, network, _ := net.ParseCIDR("10.8.0.2/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: key.PublicKey(), AllowedIPs: []net.IPNet{*network}}}
	if err := a.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("orphan live peer not removed")
	}
}
