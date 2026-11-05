package runtime

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"moorlan/internal/pair"
	"moorlan/internal/payload"
)

// errAlreadyAbsent means the peer was not in SQLite (and was not a live orphan
// before this call). Admin --remove reports it; unpair with a valid token treats
// it as idempotent success (lost-204 retries).
var errAlreadyAbsent = errors.New("peer already absent")

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

// Remove deletes the peer from SQLite after checking the phone's HMAC credential,
// then reconciles. Success means the peer is gone from SQLite (REQUIREMENTS:
// DB already won; live MAY lag). Reconcile failure is logged, not returned.
// A valid token against an already-absent peer is idempotent success (204).
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
	err = a.removeManaged(ctx, client, publicKey)
	if errors.Is(err, errAlreadyAbsent) {
		return nil
	}
	return err
}

// RemoveManaged deletes a peer by WireGuard public key only. Labels are admin
// hints and may duplicate, so they are not accepted here. Success means the
// peer is gone from SQLite; reconcile failure is logged (DB already won).
// Retries after a DB-won remove (live orphan) succeed. A never-enrolled key
// that is also absent live returns an error.
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
	client, err := a.client()
	if err != nil {
		return "", err
	}
	defer client.Close()
	if err := a.removeManaged(ctx, client, publicKey); err != nil {
		if errors.Is(err, errAlreadyAbsent) {
			return "", fmt.Errorf("no managed peer with public key %q", publicKey)
		}
		return "", err
	}
	return publicKey, nil
}

func (a *Assigner) removeManaged(ctx context.Context, client wireguardClient, publicKey string) error {
	key, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return err
	}
	publicKey = key.String()

	liveBefore := false
	if device, err := client.Device(a.Host.Snap.Name); err == nil {
		for _, p := range device.Peers {
			if p.PublicKey == key {
				liveBefore = true
				break
			}
		}
	}

	deleted, err := a.store.delete(ctx, publicKey)
	if err != nil {
		return err
	}

	// Always attempt reconcile so live catches up. Failure must not flip a
	// DB-won remove into an API failure — next reconcile or boot clears orphans.
	if err := a.reconcile(ctx, client); err != nil {
		log.Printf("moorlan: reconcile after removing peer %s: %v (database already updated; next reconcile will retry)", publicKey, err)
	}

	if deleted || liveBefore {
		return nil
	}
	return errAlreadyAbsent
}
