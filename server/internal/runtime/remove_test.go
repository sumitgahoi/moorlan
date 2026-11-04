package runtime

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"
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
	raw, _ := os.ReadFile(a.Host.ConfPath)
	if len(rows) != 0 || len(pending) != 0 || len(client.device.Peers) != 0 || strings.Contains(string(raw), peerPub(key)) {
		t.Fatal("removal incomplete")
	}
	// A completed removal makes the address reusable.
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
	for _, failure := range []string{"save", "apply"} {
		t.Run(failure, func(t *testing.T) {
			a, client, key := fixture(t)
			lease, err := a.Assign(context.Background(), peerPub(key), "phone")
			if err != nil {
				t.Fatal(err)
			}
			if failure == "save" {
				a.writeConfig = func(string, []byte) error { return errors.New("disk failure") }
			} else {
				client.configureErr = errors.New("device failure")
			}
			if err := a.Remove(context.Background(), peerPub(key), lease.UnpairToken); err == nil {
				t.Fatal("failure ignored")
			}
			rows, _ := a.store.list(context.Background())
			pending, _ := a.store.pending(context.Background())
			if len(rows) != 0 || len(pending) != 1 {
				t.Fatal("assignment not deleted or intent lost")
			}
			// New process, same database: no client retry is needed to finish removal.
			a.store.db.Close()
			config, _ := readConfig(a.Host.ConfPath)
			store, err := openStore(a.Host.ConfPath+".moorlan.db", client.device.PublicKey.String(), config)
			if err != nil {
				t.Fatal(err)
			}
			defer store.db.Close()
			a.store = store
			a.writeConfig = nil
			client.configureErr = nil
			if err := a.Reconcile(context.Background()); err != nil {
				t.Fatal(err)
			}
			if len(client.device.Peers) != 0 {
				t.Fatal("removed peer resurrected")
			}
		})
	}
}
func TestWrongUnpairCredentialDoesNotMutate(t *testing.T) {
	a, client, key := fixture(t)
	before, _ := os.ReadFile(a.Host.ConfPath)
	if err := a.Remove(context.Background(), peerPub(key), "wrong"); !errors.Is(err, pair.ErrUnauthorized) {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(a.Host.ConfPath)
	pending, _ := a.store.pending(context.Background())
	if len(client.changes) != 0 || len(pending) != 0 || string(before) != string(after) {
		t.Fatal("unauthorized mutation")
	}
}

func TestUnpairNeverRemovesUnmanagedPeers(t *testing.T) {
	a, client, key := fixture(t)
	_, network, _ := net.ParseCIDR("10.8.0.2/32")
	client.device.Peers = []wgtypes.Peer{{PublicKey: key.PublicKey(), AllowedIPs: []net.IPNet{*network}}}
	credential, _ := unpairCredential(client.device.PrivateKey, key.PublicKey())
	for _, saved := range []bool{false, true} {
		if saved {
			os.WriteFile(a.Host.ConfPath, []byte("[Interface]\nPrivateKey = original-secret\n[Peer]\nPublicKey = "+peerPub(key)+"\nAllowedIPs = 10.8.0.2/32\n"), 0600)
		}
		if err := a.Remove(context.Background(), peerPub(key), credential); err == nil {
			t.Fatal("removed unmanaged peer")
		}
	}
	if len(client.changes) != 0 {
		t.Fatal("unmanaged live state changed")
	}
}
