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

func TestUnpairDeletesRecordAndIsRetryable(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err != nil {
			t.Fatal(err)
		}
	}
	rows, _ := a.store.list(context.Background())
	pending, _ := a.store.pending(context.Background())
	if len(rows) != 0 || len(pending) != 0 || len(client.device.Peers) != 0 {
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

func TestUnpairFailureAndRestartCompleteDeletion(t *testing.T) {
	a, client, key := fixture(t)
	lease, err := a.Assign(context.Background(), peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	client.configureErr = errors.New("device failure")
	if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err == nil {
		t.Fatal("failure ignored")
	}
	rows, _ := a.store.list(context.Background())
	pending, _ := a.store.pending(context.Background())
	if len(rows) != 0 || len(pending) != 1 {
		t.Fatal("assignment not deleted or intent lost")
	}
	a.store.db.Close()
	store, err := openStore(a.Host.StorePath, client.device.PublicKey.String())
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
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
	pending, _ := a.store.pending(context.Background())
	if len(client.changes) != 0 || len(pending) != 0 {
		t.Fatal("unauthorized mutation")
	}
}

func TestUnpairNeverRemovesUnknownPeers(t *testing.T) {
	a, client, key := fixture(t)
	_, network, _ := net.ParseCIDR("10.8.0.2/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: key.PublicKey(), AllowedIPs: []net.IPNet{*network}}}
	credential, _ := unpairCredential(client.device.PrivateKey, key.PublicKey())
	if err := a.Remove(context.Background(), peerPub(key), credential); err == nil {
		t.Fatal("removed unmanaged peer")
	}
	if len(client.changes) != 0 {
		t.Fatal("unmanaged live state changed")
	}
}

func TestAdminRemoveRetryFinishesPendingByPublicKey(t *testing.T) {
	a, client, key := fixture(t)
	if _, err := a.Assign(context.Background(), peerPub(key), "Kitchen iPhone"); err != nil {
		t.Fatal(err)
	}
	client.configureErr = errors.New("device failure")
	if _, err := a.RemoveManaged(context.Background(), peerPub(key)); err == nil {
		t.Fatal("expected live failure")
	}
	if len(client.device.Peers) != 1 {
		t.Fatal("peer should still be live after failed apply")
	}
	client.configureErr = nil
	removed, err := a.RemoveManaged(context.Background(), peerPub(key))
	if err != nil || removed != peerPub(key) {
		t.Fatalf("key retry: %q %v", removed, err)
	}
	if len(client.device.Peers) != 0 {
		t.Fatal("pending removal not applied on key retry")
	}
}
