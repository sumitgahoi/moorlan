package runtime

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"time"

	"github.com/pion/stun/v3"
)

// DiscoverPublicEndpoint tries built-in STUN services. Each service has a
// bounded attempt so an unreachable first service cannot prevent fallback.
func DiscoverPublicEndpoint(ctx context.Context, listenPort int) (string, error) {
	return discoverPublicEndpoint(ctx, listenPort, DiscoverEndpoint)
}

func discoverPublicEndpoint(ctx context.Context, listenPort int, lookup func(context.Context, string, int) (string, error)) (string, error) {
	var failures []error
	for _, server := range []string{"stun.l.google.com:19302", "stun.cloudflare.com:3478"} {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		attempt, cancel := context.WithTimeout(ctx, 2*time.Second)
		endpoint, err := lookup(attempt, server, listenPort)
		cancel()
		if err == nil {
			return endpoint, nil
		}
		failures = append(failures, fmt.Errorf("%s: %w", server, err))
	}
	return "", errors.Join(failures...)
}

// DiscoverEndpoint discovers only the public IP. The ephemeral STUN socket's
// mapped port is not WireGuard's port; inbound WireGuard still needs a matching
// router port forward. -endpoint supports DDNS or a different external port.
func DiscoverEndpoint(ctx context.Context, server string, listenPort int) (string, error) {
	if listenPort < 1 || listenPort > 65535 {
		return "", fmt.Errorf("invalid WireGuard listen port")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "udp4", server)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	request := stun.MustBuild(stun.TransactionID, stun.BindingRequest)
	buffer := make([]byte, 2048)
	for attempt := 0; attempt < 3; attempt++ {
		deadline := time.Now().Add((500 * time.Millisecond) << attempt)
		if limit, ok := ctx.Deadline(); ok && limit.Before(deadline) {
			deadline = limit
		}
		if err := conn.SetDeadline(deadline); err != nil {
			return "", err
		}
		if _, err := conn.Write(request.Raw); err != nil {
			return "", err
		}
		for {
			n, err := conn.Read(buffer)
			if err != nil {
				if ctx.Err() != nil {
					return "", ctx.Err()
				}
				if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
					break
				}
				return "", err
			}
			response := &stun.Message{Raw: append([]byte(nil), buffer[:n]...)}
			if err := response.Decode(); err != nil {
				return "", fmt.Errorf("invalid STUN response: %w", err)
			}
			if response.TransactionID != request.TransactionID {
				continue
			}
			if response.Type != stun.BindingSuccess {
				return "", fmt.Errorf("STUN server rejected binding request")
			}
			var mapped stun.XORMappedAddress
			if err := mapped.GetFrom(response); err != nil {
				return "", err
			}
			ip := mapped.IP.To4()
			_, carrierNAT, _ := net.ParseCIDR("100.64.0.0/10")
			if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || carrierNAT.Contains(ip) {
				return "", fmt.Errorf("STUN did not return a public IPv4 address")
			}
			return net.JoinHostPort(ip.String(), strconv.Itoa(listenPort)), nil
		}
	}
	return "", fmt.Errorf("STUN server did not respond")
}
