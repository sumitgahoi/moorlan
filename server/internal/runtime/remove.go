package runtime

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/pair"
	"moorlan/internal/payload"
)

// A stable, per-peer capability survives restarts without a separate credential
// database. It is domain-separated from WireGuard operations and never reveals
// the server private key. Changing that key requires pairing again.
func unpairCredential(serverPrivate, peerPublic wgtypes.Key) (string, error) {
	if serverPrivate == (wgtypes.Key{}) {
		return "", fmt.Errorf("WireGuard has no configured private key")
	}
	mac := hmac.New(sha256.New, serverPrivate[:])
	_, _ = mac.Write([]byte("moorlan/unpair/v1\x00"))
	_, _ = mac.Write(peerPublic[:])
	return hex.EncodeToString(mac.Sum(nil)), nil
}

// Remove deletes the assignment after checking the phone's HMAC credential.
// The journal is cleared only after applying succeeds.
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
	expected, err := unpairCredential(device.PrivateKey, key)
	if err != nil {
		return err
	}
	if !hmac.Equal([]byte(expected), []byte(credential)) {
		return pair.ErrUnauthorized
	}
	label := ""
	if peer, err := a.store.lookupPublicKey(ctx, publicKey); err == nil {
		label = peer.Label
	} else if peer, err := a.store.lookupPendingKey(ctx, publicKey); err == nil {
		label = peer.Label
	}
	return a.removeManaged(ctx, client, publicKey, label)
}

// RemoveManaged deletes a peer by WireGuard public key only. Labels are admin
// hints and may duplicate, so they are not accepted here. Retries resolve
// pending removals when SQLite committed the deletion but live apply failed.
func (a *Assigner) RemoveManaged(ctx context.Context, publicKey string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	publicKey = strings.TrimSpace(publicKey)
	if !payload.ValidKey(publicKey) {
		return "", fmt.Errorf("peer WireGuard public key is required")
	}
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return "", err
	}
	publicKey = key.String()
	peer, err := a.store.lookupPublicKey(ctx, publicKey)
	if err != nil {
		peer, err = a.store.lookupPendingKey(ctx, publicKey)
		if err != nil {
			return "", err
		}
	}
	client, err := a.client()
	if err != nil {
		return "", err
	}
	defer client.Close()
	if err := a.removeManaged(ctx, client, peer.PublicKey, peer.Label); err != nil {
		return "", err
	}
	return peer.PublicKey, nil
}

func (a *Assigner) removeManaged(ctx context.Context, client wireguardClient, publicKey, label string) error {
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return err
	}
	publicKey = key.String()
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
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
				return fmt.Errorf("cannot unpair an unmanaged live peer")
			}
		}
		// Already removed; retries are no-ops.
		return a.reconcile(ctx, client)
	}
	if label == "" {
		for _, p := range peers {
			if p.PublicKey == publicKey {
				label = p.Label
				break
			}
		}
	}
	if err = a.store.remove(ctx, publicKey, label); err != nil {
		return err
	}
	return a.reconcile(ctx, client)
}
