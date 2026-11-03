package runtime

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"peerdoor/internal/pair"
)

// A stable, per-peer capability survives restarts without a separate credential
// database. It is domain-separated from WireGuard operations and never reveals
// the server private key. Changing that key requires pairing again.
func unjoinCredential(serverPrivate, peerPublic wgtypes.Key) (string, error) {
	if serverPrivate == (wgtypes.Key{}) {
		return "", fmt.Errorf("WireGuard has no configured private key")
	}
	mac := hmac.New(sha256.New, serverPrivate[:])
	_, _ = mac.Write([]byte("peerdoor/unjoin/v1\x00"))
	_, _ = mac.Write(peerPublic[:])
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// Remove deletes the assignment and journals the live removal in one transaction.
// The journal is cleared only after saving and applying succeeds.
func (a *Assigner) Remove(ctx context.Context, publicKey, credential string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return pair.ErrUnauthorized
	}
	publicKey = key.String()
	client, err := a.client()
	if err != nil {
		return err
	}
	defer client.Close()
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
	}
	expected, err := unjoinCredential(device.PrivateKey, key)
	if err != nil {
		return err
	}
	if !hmac.Equal([]byte(expected), []byte(credential)) {
		return pair.ErrUnauthorized
	}
	config, err := readConfig(a.Host.ConfPath)
	if err != nil {
		return err
	}
	if peerKeys(config.external)[publicKey] {
		return fmt.Errorf("cannot unjoin a peer outside PeerDoor management")
	}
	peers, err := a.store.list(ctx)
	if err != nil {
		return err
	}
	pending, err := a.store.pending(ctx)
	if err != nil {
		return err
	}
	known := peerKeys(peers)[publicKey]
	for _, p := range pending {
		if p == publicKey {
			known = true
		}
	}
	if !known {
		for _, p := range device.Peers {
			if p.PublicKey == key {
				return fmt.Errorf("cannot unjoin an unmanaged live peer")
			}
		}
	}
	if err = a.store.remove(ctx, publicKey); err != nil {
		return err
	}
	return a.reconcile(ctx, client)
}
