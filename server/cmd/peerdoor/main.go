package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"peerdoor/internal/pair"
	"peerdoor/internal/payload"
	"peerdoor/internal/qr"
	"peerdoor/internal/runtime"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "peerdoor: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	unjoin := flag.Bool("unjoin", false, "show an unjoin QR and accept deletion requests only")
	name := flag.String("iface", "wg0", "existing WireGuard interface (Linux)")
	conf := flag.String("conf", "", "advanced: wg-quick config path (default /etc/wireguard/<iface>.conf)")
	lanIface := flag.String("lan-iface", "", "advanced: override automatic LAN interface selection")
	endpoint := flag.String("endpoint", "", "public WireGuard host:port; overrides STUN discovery (e.g. DDNS)")
	port := flag.Int("pair-port", 8756, "advanced: HTTP pairing port on the trusted LAN")
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "Usage: peerdoor [--unjoin] [-iface wg0] [-endpoint host:port]\n\nOptions:")
		for _, advanced := range []bool{false, true} {
			if advanced {
				fmt.Fprintln(flag.CommandLine.Output(), "\nAdvanced options:")
			}
			flag.VisitAll(func(f *flag.Flag) {
				isAdvanced := f.Name != "iface" && f.Name != "endpoint" && f.Name != "unjoin"
				if isAdvanced == advanced {
					fmt.Fprintf(flag.CommandLine.Output(), "  -%s (default %q)\n      %s\n", f.Name, f.DefValue, f.Usage)
				}
			})
		}
	}
	flag.Parse()
	if !*unjoin && *endpoint != "" {
		if _, _, err := payload.SplitEndpoint(*endpoint); err != nil {
			return err
		}
	}
	release, err := runtime.LockInterface(*name)
	if err != nil {
		return err
	}
	defer release()
	var host runtime.Host
	if *unjoin {
		host, err = runtime.DiscoverUnjoin(*name, *conf, *lanIface, *port)
	} else {
		host, err = runtime.Discover(*name, *conf, *lanIface, *endpoint, *port)
	}
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	addr := net.JoinHostPort(host.PairHost, strconv.Itoa(host.PairPort))
	controlURL := "http://" + addr + "/v1/pair"
	assigner, err := runtime.OpenAssigner(ctx, host)
	if err != nil {
		return err
	}
	defer assigner.Close()
	var text string
	var handler http.Handler
	if *unjoin {
		text, err = payload.MarshalUnjoin(payload.UnjoinCard{V: 2, Action: "unjoin", ServerPublicKey: host.Snap.PublicKey, UnjoinURL: controlURL})
		handler = pair.NewUnjoinOnly(assigner)
	} else {
		if host.Endpoint == "" {
			fmt.Println("Discovering public IPv4 via STUN...")
			discovery, cancel := context.WithTimeout(ctx, 5*time.Second)
			host.Endpoint, err = runtime.DiscoverPublicEndpoint(discovery, host.Snap.ListenPort)
			cancel()
			if err != nil {
				return fmt.Errorf("public endpoint discovery failed: %w; supply -endpoint host:port", err)
			}
			fmt.Printf("endpoint   %s (STUN IP + WireGuard port; requires matching UDP port forwarding)\n", host.Endpoint)
		} else {
			fmt.Printf("endpoint   %s (explicit)\n", host.Endpoint)
		}
		assigner.Host = host
		text, err = payload.Marshal(payload.Card{V: 3, PairURL: controlURL, ServerPublicKey: host.Snap.PublicKey})
		handler = pair.New(assigner)
	}
	if err != nil {
		return err
	}
	server := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	// Bind before displaying the invitation, so the QR never advertises a failed listener.
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w; use -pair-port to choose another port", addr, err)
	}
	defer listener.Close()
	fmt.Printf("interface  %s\ntrusted LAN %s (%s)\nservice    %s\n", host.Snap.Name, host.LAN.IP, host.LAN.CIDR, controlURL)
	if err := qr.WriteANSI(os.Stdout, text); err != nil {
		return err
	}
	if *unjoin {
		fmt.Println("\nScan with an already-paired device on the home LAN to unjoin.\nDeletion only; the device must provide its saved credential. Ctrl-C stops the service.")
	} else {
		fmt.Println("\nScan on the trusted home LAN to add devices. Enrollment stays open until Ctrl-C.\nAnyone who can reach this service can enroll while it is running.")
	}
	errCh := make(chan error, 1)
	go func() { errCh <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return err
		}
		return nil
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}
