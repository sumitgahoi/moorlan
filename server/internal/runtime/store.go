package runtime

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
	"moorlan/internal/iface"
)

type peerStore struct{ db *sql.DB }

// initStore exclusively creates a new database; it never replaces existing state.
func initStore(path, serverKey string, livePeers int) error {
	if livePeers != 0 {
		return fmt.Errorf("cannot initialize database while the WireGuard interface has %d live peer(s); remove them, then pair through the app", livePeers)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if err != nil {
		return fmt.Errorf("initialize database %s (must not already exist): %w", path, err)
	}
	if err = file.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	db, err := connectStore(path)
	if err != nil {
		_ = os.Remove(path)
		return err
	}
	defer db.Close()
	tx, err := db.Begin()
	if err == nil {
		defer tx.Rollback()
		_, err = tx.Exec(`
 CREATE TABLE IF NOT EXISTS metadata (server_key TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS peers (public_key TEXT PRIMARY KEY NOT NULL, address TEXT UNIQUE NOT NULL, label TEXT NOT NULL DEFAULT '');`)
		if err == nil {
			_, err = tx.Exec("INSERT INTO metadata(server_key) VALUES (?)", serverKey)
		}
		if err == nil {
			err = tx.Commit()
		}
	}
	if err != nil {
		return err
	}
	// Persist the new directory entry as well as SQLite's committed contents.
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// connectStore uses SQLite's read/write-only mode, so SQLite cannot recreate a
// missing file even if it disappears between the filesystem check and opening.
func connectStore(path string) (*sql.DB, error) {
	file, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("database %s does not exist; run --add-interface", path)
		}
		return nil, err
	}
	err = file.Chmod(0600)
	file.Close()
	if err != nil {
		return nil, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	dsn := (&url.URL{Scheme: "file", Path: abs, RawQuery: "mode=rw"}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	// FULL commits make an assignment durable before it reaches WireGuard.
	if _, err = db.Exec("PRAGMA synchronous=FULL"); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func openStore(path, serverKey string) (*peerStore, error) {
	db, err := connectStore(path)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (*peerStore, error) { db.Close(); return nil, err }
	var storedKey string
	err = db.QueryRow("SELECT server_key FROM metadata LIMIT 1").Scan(&storedKey)
	if err != nil {
		return fail(fmt.Errorf("database %s is not initialized or cannot be read; run --remove-interface then --add-interface and re-pair: %w", path, err))
	}
	if storedKey != serverKey {
		return fail(fmt.Errorf("WireGuard server key changed; database belongs to a different server identity"))
	}
	if err = ensurePeerLabelColumn(db); err != nil {
		return fail(err)
	}
	// Drop legacy deletion journal if an older database still has it.
	if _, err = db.Exec(`DROP TABLE IF EXISTS pending_removals`); err != nil {
		return fail(err)
	}
	return &peerStore{db: db}, nil
}

func ensurePeerLabelColumn(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(peers)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	hasLabel := false
	for rows.Next() {
		var cid int
		var name, ctype string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notNull, &dflt, &pk); err != nil {
			return err
		}
		if name == "label" {
			hasLabel = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !hasLabel {
		if _, err := db.Exec(`ALTER TABLE peers ADD COLUMN label TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
	}
	_, err = db.Exec(`DROP INDEX IF EXISTS peers_label_unique`)
	return err
}

func (s *peerStore) list(ctx context.Context) ([]iface.Peer, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT public_key,address,label FROM peers ORDER BY public_key")
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

func (s *peerStore) insert(ctx context.Context, key, address, label string) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO peers(public_key,address,label) VALUES (?,?,?)", key, address, label)
	return err
}
func (s *peerStore) setLabel(ctx context.Context, key, label string) error {
	_, err := s.db.ExecContext(ctx, "UPDATE peers SET label=? WHERE public_key=?", label, key)
	return err
}
func (s *peerStore) lookupPublicKey(ctx context.Context, key string) (iface.Peer, error) {
	var address, label string
	err := s.db.QueryRowContext(ctx, "SELECT address,label FROM peers WHERE public_key=?", key).Scan(&address, &label)
	if err == sql.ErrNoRows {
		return iface.Peer{}, fmt.Errorf("no managed peer with public key %q", key)
	}
	if err != nil {
		return iface.Peer{}, err
	}
	return iface.Peer{PublicKey: key, AllowedIPs: []string{address}, Label: label}, nil
}

// delete removes the peer row. It returns whether a row was deleted.
func (s *peerStore) delete(ctx context.Context, key string) (bool, error) {
	res, err := s.db.ExecContext(ctx, "DELETE FROM peers WHERE public_key=?", key)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// CountPeers returns how many peer rows exist.
func CountPeers(path string) (peers int, err error) {
	db, err := connectStore(path)
	if err != nil {
		return 0, err
	}
	defer db.Close()
	if err = db.QueryRow(`SELECT COUNT(*) FROM peers`).Scan(&peers); err != nil {
		return 0, err
	}
	return peers, nil
}
