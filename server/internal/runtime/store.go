package runtime

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"

	_ "modernc.org/sqlite"
	"moorlan/internal/iface"
)

type peerStore struct{ db *sql.DB }

const schemaSQL = `
CREATE TABLE IF NOT EXISTS interfaces (
  name TEXT PRIMARY KEY NOT NULL,
  server_public_key TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS peers (
  interface TEXT NOT NULL REFERENCES interfaces(name),
  public_key TEXT NOT NULL,
  address TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (interface, public_key),
  UNIQUE (interface, address)
);`

// MigrateStore opens (or creates) the peer database and applies additive schema
// migrations, then closes it. Safe to call from --setup.
func MigrateStore(path string) error {
	if path == "" {
		path = DefaultStorePath
	}
	store, err := openStore(path)
	if err != nil {
		return err
	}
	return store.db.Close()
}

// openStore opens or creates the host peer database.
func openStore(path string) (*peerStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(abs); err != nil {
		if !os.IsNotExist(err) {
			return nil, err
		}
		file, err := os.OpenFile(abs, os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return nil, fmt.Errorf("create database %s: %w", path, err)
		}
		if err := file.Close(); err != nil {
			_ = os.Remove(abs)
			return nil, err
		}
	} else if err := os.Chmod(abs, 0600); err != nil {
		return nil, err
	}
	dsn := (&url.URL{Scheme: "file", Path: abs, RawQuery: "mode=rw"}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	fail := func(err error) (*peerStore, error) { db.Close(); return nil, err }
	if _, err = db.Exec("PRAGMA synchronous=FULL"); err != nil {
		return fail(err)
	}
	if _, err = db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		return fail(err)
	}
	if _, err = db.Exec(schemaSQL); err != nil {
		return fail(err)
	}
	// Drop legacy tables/columns from older single-iface databases if present.
	if _, err = db.Exec(`DROP TABLE IF EXISTS pending_removals`); err != nil {
		return fail(err)
	}
	if _, err = db.Exec(`DROP TABLE IF EXISTS metadata`); err != nil {
		return fail(err)
	}
	// Rename peers.interface_id → peers.interface on older databases.
	var n int
	if err = db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('peers') WHERE name='interface_id'`).Scan(&n); err != nil {
		return fail(err)
	}
	if n > 0 {
		if _, err = db.Exec(`ALTER TABLE peers RENAME COLUMN interface_id TO interface`); err != nil {
			return fail(err)
		}
	}
	return &peerStore{db: db}, nil
}

// bindInterface records or verifies the sticky server public key for iface.
// The key is set once on first successful use and must not change.
func (s *peerStore) bindInterface(ctx context.Context, name, serverKey string) error {
	var stored string
	err := s.db.QueryRowContext(ctx, `SELECT server_public_key FROM interfaces WHERE name=?`, name).Scan(&stored)
	if err == sql.ErrNoRows {
		_, err = s.db.ExecContext(ctx, `INSERT INTO interfaces(name, server_public_key) VALUES (?,?)`, name, serverKey)
		return err
	}
	if err != nil {
		return err
	}
	if stored != serverKey {
		return fmt.Errorf("WireGuard server key for %s does not match the database; refusing to operate on this interface", name)
	}
	return nil
}

func (s *peerStore) interfaceNames(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT name FROM interfaces ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	return out, rows.Err()
}

func (s *peerStore) list(ctx context.Context, ifaceName string) ([]iface.Peer, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT public_key,address,label FROM peers WHERE interface=? ORDER BY public_key`, ifaceName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []iface.Peer
	for rows.Next() {
		var key, address, label string
		if err := rows.Scan(&key, &address, &label); err != nil {
			return nil, err
		}
		out = append(out, iface.Peer{PublicKey: key, AllowedIPs: []string{address}, Label: label})
	}
	return out, rows.Err()
}

// ListedPeer is one enrolled peer for --list-peers.
type ListedPeer struct {
	Interface string
	PublicKey string
	Address   string
	Label     string
}

func (s *peerStore) listAll(ctx context.Context, ifaceFilter string) ([]ListedPeer, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if ifaceFilter == "" {
		rows, err = s.db.QueryContext(ctx, `SELECT interface,public_key,address,label FROM peers ORDER BY interface, public_key`)
	} else {
		rows, err = s.db.QueryContext(ctx, `SELECT interface,public_key,address,label FROM peers WHERE interface=? ORDER BY public_key`, ifaceFilter)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ListedPeer
	for rows.Next() {
		var p ListedPeer
		if err := rows.Scan(&p.Interface, &p.PublicKey, &p.Address, &p.Label); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *peerStore) insert(ctx context.Context, ifaceName, key, address, label string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO peers(interface,public_key,address,label) VALUES (?,?,?,?)`, ifaceName, key, address, label)
	return err
}

func (s *peerStore) setLabel(ctx context.Context, ifaceName, key, label string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE peers SET label=? WHERE interface=? AND public_key=?`, label, ifaceName, key)
	return err
}

func (s *peerStore) lookupPublicKey(ctx context.Context, ifaceName, key string) (iface.Peer, error) {
	var address, label string
	err := s.db.QueryRowContext(ctx, `SELECT address,label FROM peers WHERE interface=? AND public_key=?`, ifaceName, key).Scan(&address, &label)
	if err == sql.ErrNoRows {
		return iface.Peer{}, fmt.Errorf("no managed peer with public key %q on %s", key, ifaceName)
	}
	if err != nil {
		return iface.Peer{}, err
	}
	return iface.Peer{PublicKey: key, AllowedIPs: []string{address}, Label: label}, nil
}

// delete removes the peer row. It returns whether a row was deleted.
func (s *peerStore) delete(ctx context.Context, ifaceName, key string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM peers WHERE interface=? AND public_key=?`, ifaceName, key)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// ListPeers returns enrolled peers from SQLite (optionally filtered by interface).
func ListPeers(ctx context.Context, storePath, ifaceFilter string) ([]ListedPeer, error) {
	if _, err := os.Stat(storePath); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	store, err := openStore(storePath)
	if err != nil {
		return nil, err
	}
	defer store.db.Close()
	return store.listAll(ctx, ifaceFilter)
}

// ReconcileTargets returns the stable-ordered set of interfaces to reconcile:
// only enabled YAML names. An interface that is enabled: false or missing from
// YAML is not projected, even when it still has peer rows. An explicit filter
// that is not enabled is an error.
func ReconcileTargets(enabledNames []string, ifaceFilter string) ([]string, error) {
	seen := map[string]bool{}
	var out []string
	for _, name := range enabledNames {
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}
	sort.Strings(out)
	if ifaceFilter == "" {
		return out, nil
	}
	if !seen[ifaceFilter] {
		return nil, fmt.Errorf("interface %s is not enabled in site conf", ifaceFilter)
	}
	return []string{ifaceFilter}, nil
}
