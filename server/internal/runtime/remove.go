package runtime

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/iface"
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
	expected, err := unpairCredential(device.PrivateKey, key)
	if err != nil {
		return err
	}
	if !hmac.Equal([]byte(expected), []byte(credential)) {
		return pair.ErrUnauthorized
	}
	return a.removeManaged(ctx, client, publicKey)
}

// RemoveManaged deletes a peer by WireGuard public key, or by label when that
// label matches exactly one managed peer. No phone credential is required.
func (a *Assigner) RemoveManaged(ctx context.Context, ref string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return "", fmt.Errorf("peer public key or label is required")
	}
	var peer iface.Peer
	var err error
	if payload.ValidKey(ref) {
		key, parseErr := wgtypes.ParseKey(ref)
		if parseErr != nil {
			return "", parseErr
		}
		peer, err = a.store.lookupPublicKey(ctx, key.String())
	} else {
		if err := payload.ValidateLabel(ref); err != nil {
			return "", fmt.Errorf("peer public key or label is required")
		}
		peer, err = a.store.lookupLabel(ctx, payload.NormalizeLabel(ref))
	}
	if err != nil {
		return "", err
	}
	client, err := a.client()
	if err != nil {
		return "", err
	}
	defer client.Close()
	if err := a.removeManaged(ctx, client, peer.PublicKey); err != nil {
		return "", err
	}
	return peer.PublicKey, nil
}

func (a *Assigner) removeManaged(ctx context.Context, client wireguardClient, publicKey string) error {
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return err
	}
	publicKey = key.String()
	device, err := client.Device(a.Host.Snap.Name)
	if err != nil {
		return err
	}
	config, err := readConfig(a.Host.ConfPath)
	if err != nil {
		return err
	}
	if peerKeys(config.external)[publicKey] {
		return fmt.Errorf("cannot unpair a peer outside Moorlan management")
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
	}
	if err = a.store.remove(ctx, publicKey); err != nil {
		return err
	}
	return a.reconcile(ctx, client)
}
