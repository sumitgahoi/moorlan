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

	"moorlan/internal/payload"
)

type Lease struct {
	Address             string   `json:"address"`
	Prefixes            []string `json:"prefixes"`
	LAN                 string   `json:"lan"`
	PublicKey           string   `json:"public_key"`
	Endpoint            string   `json:"endpoint"`
	MTU                 int      `json:"mtu,omitempty"`
	PersistentKeepalive int      `json:"persistent_keepalive"`
	UnpairToken         string   `json:"unpair_token"`
	Label               string   `json:"label"`
}

type Assigner interface {
	Assign(context.Context, string, string) (Lease, error)
	Remove(context.Context, string, string) error
}

var ErrUnauthorized = errors.New("invalid unpair credential")

type request struct {
	PublicKey string `json:"public_key"`
	Label     string `json:"label"`
}

// New serves enrollment and unpair. onSuccess runs after HTTP 2xx mutations only
// (nil is fine). Bodies are plaintext JSON on the trusted LAN (see README).
func New(assign Assigner, onSuccess func()) http.Handler {
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
		if err := payload.ValidateLabel(body.Label); err != nil {
			writeError(w, 400, err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		lease, err := assign.Assign(ctx, key, payload.NormalizeLabel(body.Label))
		if err != nil {
			log.Printf("pairing assignment failed: %v", err)
			writeError(w, 500, "could not register peer; check server logs and retry")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(lease); err != nil {
			return
		}
		if onSuccess != nil {
			onSuccess()
		}
	})
	mux.HandleFunc("DELETE /v1/pair", unpairHandler(assign.Remove, onSuccess))
	return mux
}

// NewUnpairOnly never registers the enrollment route, even with a valid token.
func NewUnpairOnly(assign Assigner, onSuccess func()) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("DELETE /v1/pair", unpairHandler(assign.Remove, onSuccess))
	return mux
}

func unpairHandler(remove func(context.Context, string, string) error, onSuccess func()) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			PublicKey   string `json:"public_key"`
			UnpairToken string `json:"unpair_token"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			writeError(w, 400, "unpair request is not valid json")
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			writeError(w, 400, "expected exactly one JSON object")
			return
		}
		key := strings.TrimSpace(body.PublicKey)
		if !payload.ValidKey(key) || body.UnpairToken == "" {
			writeError(w, 400, "public key and unpair credential are required")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		if err := remove(ctx, key, body.UnpairToken); err != nil {
			if errors.Is(err, ErrUnauthorized) {
				writeError(w, 403, "unpair credential does not match")
				return
			}
			log.Printf("peer removal failed: %v", err)
			writeError(w, 500, "could not remove peer; check server logs")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		if onSuccess != nil {
			onSuccess()
		}
	}
}

func writeError(w http.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(struct {
		Error string `json:"error"`
	}{message})
}
