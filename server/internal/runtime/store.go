package runtime

import (
	"context"
	"database/sql"
	"fmt"
	"os"

	_ "modernc.org/sqlite"
	"peerdoor/internal/iface"
)

type peerStore struct{ db *sql.DB }

func openStore(path, serverKey string, config configFile) (*peerStore, error) {
	_, err := os.Stat(path)
	if os.IsNotExist(err) && len(config.managed) != 0 {
		return nil, fmt.Errorf("PeerDoor database is missing but its config block contains peers; restore the database before starting")
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
func (s *peerStore) list(ctx context.Context) ([]iface.Peer, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT public_key,address FROM peers ORDER BY public_key")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []iface.Peer
	for rows.Next() {
		var key, address string
		if err := rows.Scan(&key, &address); err != nil {
			return nil, err
		}
		out = append(out, iface.Peer{PublicKey: key, AllowedIPs: []string{address}})
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
func (s *peerStore) insert(ctx context.Context, key, address string) error {
	_, err := s.db.ExecContext(ctx, "INSERT INTO peers(public_key,address) VALUES (?,?)", key, address)
	return err
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
