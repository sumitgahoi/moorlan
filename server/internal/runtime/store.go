package runtime

import (
	"context"
	"database/sql"
	"fmt"
	"os"

	_ "modernc.org/sqlite"
	"moorlan/internal/iface"
)

type peerStore struct{ db *sql.DB }

// storePath prefers the Moorlan database name and renames a PeerDoor-era file once.
func storePath(confPath string) string {
	modern := confPath + ".moorlan.db"
	legacy := confPath + ".peerdoor.db"
	if _, err := os.Stat(modern); err == nil {
		return modern
	}
	if _, err := os.Stat(legacy); err == nil {
		if err := os.Rename(legacy, modern); err == nil {
			return modern
		}
		return legacy
	}
	return modern
}

func openStore(path, serverKey string, config configFile) (*peerStore, error) {
	_, err := os.Stat(path)
	if os.IsNotExist(err) && len(config.managed) != 0 {
		return nil, fmt.Errorf("Moorlan database is missing but its config block contains peers; restore the database before starting")
	}
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = file.Chmod(0600); err != nil {
		file.Close()
		return nil, err
	}
	file.Close()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	fail := func(err error) (*peerStore, error) { db.Close(); return nil, err }
	// FULL commits make an assignment durable before it reaches WireGuard.
	_, err = db.Exec(`PRAGMA synchronous=FULL;
 CREATE TABLE IF NOT EXISTS metadata (server_key TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS peers (public_key TEXT PRIMARY KEY NOT NULL, address TEXT UNIQUE NOT NULL);
 CREATE TABLE IF NOT EXISTS pending_removals (public_key TEXT PRIMARY KEY NOT NULL);`)
	if err != nil {
		return fail(err)
	}
	if err = ensurePeerLabelColumn(db); err != nil {
		return fail(err)
	}
	var storedKey string
	err = db.QueryRow("SELECT server_key FROM metadata LIMIT 1").Scan(&storedKey)
	if err == sql.ErrNoRows {
		_, err = db.Exec("INSERT INTO metadata(server_key) VALUES (?)", serverKey)
	} else if err == nil && storedKey != serverKey {
		err = fmt.Errorf("WireGuard server key changed; database belongs to a different server identity")
	}
	if err != nil {
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
	// Labels may repeat (two phones named "iPhone"); drop any older uniqueness rule.
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
func (s *peerStore) pending(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT public_key FROM pending_removals ORDER BY public_key")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, err
		}
		out = append(out, key)
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

func (s *peerStore) lookupLabel(ctx context.Context, label string) (iface.Peer, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT public_key,address,label FROM peers WHERE label=? ORDER BY public_key", label)
	if err != nil {
		return iface.Peer{}, err
	}
	defer rows.Close()
	var matches []iface.Peer
	for rows.Next() {
		var key, address, stored string
		if err := rows.Scan(&key, &address, &stored); err != nil {
			return iface.Peer{}, err
		}
		matches = append(matches, iface.Peer{PublicKey: key, AllowedIPs: []string{address}, Label: stored})
	}
	if err := rows.Err(); err != nil {
		return iface.Peer{}, err
	}
	switch len(matches) {
	case 0:
		return iface.Peer{}, fmt.Errorf("no managed peer with label %q", label)
	case 1:
		return matches[0], nil
	default:
		return iface.Peer{}, fmt.Errorf("label %q matches %d peers; remove by WireGuard public key instead", label, len(matches))
	}
}
func (s *peerStore) remove(ctx context.Context, key string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// This is a short deletion journal, not a retained peer assignment. A crash
	// between committing the deletion and applying it must not resurrect access.
	if _, err = tx.ExecContext(ctx, "INSERT OR IGNORE INTO pending_removals(public_key) VALUES (?)", key); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM peers WHERE public_key=?", key); err != nil {
		return err
	}
	return tx.Commit()
}
