package runtime

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

func TestOpenStoreRequiresExplicitInitialization(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing", "moorlan0.db")
	key := wgtypes.Key{2}.String()
	if _, err := openStore(path, key); err == nil || !strings.Contains(err.Error(), "--add-interface") {
		t.Fatalf("missing database error: %v", err)
	}
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatalf("open created the database directory: %v", err)
	}
	if err := initStore(path, key, 0); err != nil {
		t.Fatal(err)
	}
	store, err := openStore(path, key)
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	if peers, err := store.list(context.Background()); err != nil || len(peers) != 0 {
		t.Fatalf("initialized peers: %v %v", peers, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("database permissions: %v %v", info, err)
	}
}

func TestInitStoreDoesNotOverwriteOrAdoptExistingFiles(t *testing.T) {
	for _, contents := range []string{"", "existing contents"} {
		t.Run(contents, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "moorlan0.db")
			if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
				t.Fatal(err)
			}
			if err := initStore(path, wgtypes.Key{2}.String(), 0); err == nil {
				t.Fatal("initialized an existing file")
			}
			if _, err := openStore(path, wgtypes.Key{2}.String()); err == nil {
				t.Fatal("opened an uninitialized database")
			}
			raw, err := os.ReadFile(path)
			if err != nil || string(raw) != contents {
				t.Fatalf("existing file changed: %q %v", raw, err)
			}
		})
	}
}

func TestInitStoreRefusesLivePeers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "moorlan0.db")
	if err := initStore(path, wgtypes.Key{2}.String(), 1); err == nil {
		t.Fatal("initialized while live peers exist")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("created database: %v", err)
	}
}

func TestInitializedStorePreservesIdentityAndAssignments(t *testing.T) {
	a, client, key := fixture(t)
	ctx := context.Background()
	lease, err := a.Assign(ctx, peerPub(key), "phone")
	if err != nil {
		t.Fatal(err)
	}
	if err := initStore(a.Host.StorePath, client.device.PublicKey.String(), 0); err == nil {
		t.Fatal("reinitialized existing database")
	}
	if err := a.store.db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := openStore(a.Host.StorePath, wgtypes.Key{9}.String()); err == nil {
		t.Fatal("accepted a different server identity")
	}
	store, err := openStore(a.Host.StorePath, client.device.PublicKey.String())
	if err != nil {
		t.Fatal(err)
	}
	defer store.db.Close()
	peer, err := store.lookupPublicKey(ctx, peerPub(key))
	if err != nil || peer.AllowedIPs[0] != lease.Address || peer.Label != "phone" {
		t.Fatalf("assignment lost: %+v %v", peer, err)
	}
}

func TestOpenAssignerDoesNotRecreateLostDatabaseOrTouchLivePeers(t *testing.T) {
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
	if _, err := OpenAssigner(context.Background(), a.Host); err == nil {
		t.Fatal("recreated missing database")
	}
	if _, err := os.Stat(a.Host.StorePath); !os.IsNotExist(err) {
		t.Fatalf("database was recreated: %v", err)
	}
	if len(client.device.Peers) != 1 || client.device.Peers[0].PublicKey != key.PublicKey() {
		t.Fatal("live peer changed")
	}
}
