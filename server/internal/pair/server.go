package pair

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"moorlan/internal/payload"
)

type Lease struct {
	Address             string   `json:"address"`
	TunnelNetwork       string   `json:"tunnel_network"`
	HomeNetworks        []string `json:"home_networks"`
	DNSServers          []string `json:"dns_servers"`
	DNSSearch           []string `json:"dns_search,omitempty"`
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

// Notify is optional operator feedback during a pair/unpair HTTP session.
// Nil funcs are skipped (Error falls back to stderr with a moorlan: prefix).
type Notify struct {
	Paired   func(label, peerPublicKey string)
	Unpaired func(peerPublicKey string)
	Error    func(format string, args ...any)
}

func (n Notify) errorf(format string, args ...any) {
	if n.Error != nil {
		n.Error(format, args...)
		return
	}
	fmt.Fprintf(os.Stderr, "moorlan: "+format+"\n", args...)
}

// New serves enrollment and unpair. Bodies are plaintext JSON on the trusted LAN
// (see REQUIREMENTS).
func New(assign Assigner, notify Notify) http.Handler {
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
		label := payload.NormalizeLabel(body.Label)
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		lease, err := assign.Assign(ctx, key, label)
		if err != nil {
			notify.errorf("pairing assignment failed: %v", err)
			writeError(w, 500, "could not register peer; check server logs and retry")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(lease); err != nil {
			return
		}
		if notify.Paired != nil {
			notify.Paired(lease.Label, key)
		}
	})
	mux.HandleFunc("DELETE /v1/pair", unpairHandler(assign.Remove, notify))
	return mux
}

// NewUnpairOnly never registers the enrollment route, even with a valid token.
func NewUnpairOnly(assign Assigner, notify Notify) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("DELETE /v1/pair", unpairHandler(assign.Remove, notify))
	return mux
}

func unpairHandler(remove func(context.Context, string, string) error, notify Notify) http.HandlerFunc {
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
			notify.errorf("peer removal failed: %v", err)
			writeError(w, 500, "could not remove peer; check server logs")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		if notify.Unpaired != nil {
			notify.Unpaired(key)
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
