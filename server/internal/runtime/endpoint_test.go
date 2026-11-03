package runtime

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/stun/v3"
)

func TestDiscoverEndpointUsesWireGuardPort(t *testing.T) {
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	serverDone := make(chan error, 1)
	go func() {
		buffer := make([]byte, 2048)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := conn.ReadFrom(buffer)
		if err != nil {
			serverDone <- err
			return
		}
		request := &stun.Message{Raw: buffer[:n]}
		if err := request.Decode(); err != nil {
			serverDone <- err
			return
		}
		// The mapped STUN port deliberately differs from WireGuard's port.
		response := stun.MustBuild(stun.NewTransactionIDSetter(request.TransactionID), stun.BindingSuccess, &stun.XORMappedAddress{IP: net.ParseIP("203.0.113.5"), Port: 49152})
		_, err = conn.WriteTo(response.Raw, addr)
		serverDone <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	got, err := DiscoverEndpoint(ctx, conn.LocalAddr().String(), 51820)
	if err != nil || got != "203.0.113.5:51820" {
		t.Fatalf("%s %v", got, err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}
func TestDiscoverEndpointCancellation(t *testing.T) {
	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := DiscoverEndpoint(ctx, conn.LocalAddr().String(), 51820); err == nil {
		t.Fatal("expected timeout")
	}
	if time.Since(start) > time.Second {
		t.Fatal("discovery ignored deadline")
	}
}

func TestPublicEndpointFallback(t *testing.T) {
	calls := 0
	got, err := discoverPublicEndpoint(context.Background(), 51820, func(ctx context.Context, server string, port int) (string, error) {
		calls++
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 2*time.Second {
			t.Fatal("missing per-server deadline")
		}
		if port != 51820 {
			t.Fatal(port)
		}
		if calls == 1 {
			return "", errors.New("unreachable")
		}
		return "203.0.113.5:51820", nil
	})
	if err != nil || got != "203.0.113.5:51820" || calls != 2 {
		t.Fatalf("%s %v calls=%d", got, err, calls)
	}
}

func TestPublicEndpointStopsAfterSuccessOrCancellation(t *testing.T) {
	calls := 0
	lookup := func(context.Context, string, int) (string, error) { calls++; return "203.0.113.5:51820", nil }
	if _, err := discoverPublicEndpoint(context.Background(), 51820, lookup); err != nil || calls != 1 {
		t.Fatalf("%v calls=%d", err, calls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := discoverPublicEndpoint(ctx, 51820, lookup); !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal("cancelled discovery attempted a server")
	}
}

func TestPublicEndpointReportsBothFailures(t *testing.T) {
	calls := 0
	_, err := discoverPublicEndpoint(context.Background(), 51820, func(context.Context, string, int) (string, error) { calls++; return "", errors.New("unreachable") })
	if err == nil || calls != 2 || !strings.Contains(err.Error(), "stun.l.google.com") || !strings.Contains(err.Error(), "stun.cloudflare.com") {
		t.Fatalf("%v calls=%d", err, calls)
	}
}
