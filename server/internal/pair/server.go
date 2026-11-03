package pair

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"peerdoor/internal/payload"
)

type Lease struct {
	Address             string   `json:"address"`
	Prefixes            []string `json:"prefixes"`
	LAN                 string   `json:"lan"`
	PublicKey           string   `json:"public_key"`
	Endpoint            string   `json:"endpoint"`
	MTU                 int      `json:"mtu,omitempty"`
	PersistentKeepalive int      `json:"persistent_keepalive"`
	UnjoinToken         string   `json:"unjoin_token"`
}
type Assigner interface {
	Assign(context.Context, string) (Lease, error)
	Remove(context.Context, string, string) error
}

var ErrUnauthorized = errors.New("invalid unjoin credential")

type request struct {
	PublicKey string `json:"public_key"`
}

// Enrollment is open to trusted LAN users for the lifetime of the process.
// Assigner serializes mutations; the HTTP layer holds no additional mutex.
func New(assign Assigner) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/pair", func(w http.ResponseWriter, r *http.Request) {
		var body request
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			writeError(w, 400, "pairing request is not valid json")
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			writeError(w, 400, "expected exactly one JSON object")
			return
		}
		key := strings.TrimSpace(body.PublicKey)
		if !payload.ValidKey(key) {
			writeError(w, 400, "public key is not a WireGuard key")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		lease, err := assign.Assign(ctx, key)
		if err != nil {
			log.Printf("pairing assignment failed: %v", err)
			writeError(w, 500, "could not register peer; check server logs and retry")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(lease)
	})
	mux.HandleFunc("DELETE /v1/pair", unjoinHandler(assign.Remove))
	return mux
}

// NewUnjoinOnly never registers the enrollment route, even with a valid token.
func NewUnjoinOnly(assign Assigner) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("DELETE /v1/pair", unjoinHandler(assign.Remove))
	return mux
}

func unjoinHandler(remove func(context.Context, string, string) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			PublicKey   string `json:"public_key"`
			UnjoinToken string `json:"unjoin_token"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			writeError(w, 400, "unjoin request is not valid json")
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			writeError(w, 400, "expected exactly one JSON object")
			return
		}
		key := strings.TrimSpace(body.PublicKey)
		if !payload.ValidKey(key) || body.UnjoinToken == "" {
			writeError(w, 400, "public key and unjoin credential are required")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		if err := remove(ctx, key, body.UnjoinToken); err != nil {
			if errors.Is(err, ErrUnauthorized) {
				writeError(w, 403, "unjoin credential does not match")
				return
			}
			log.Printf("peer removal failed: %v", err)
			writeError(w, 500, "could not remove peer; check server logs")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func writeError(w http.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(struct {
		Error string `json:"error"`
	}{message})
}
