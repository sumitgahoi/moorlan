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

	"moorlan/internal/pair"
	"moorlan/internal/payload"
	"moorlan/internal/qr"
	"moorlan/internal/runtime"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "moorlan: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	initialize := flag.Bool("init", false, "create the SQLite database for an empty moorlanN device and exit")
	unpair := flag.Bool("unpair", false, "show an unpair QR and accept deletion requests only")
	remove := flag.String("remove", "", "remove a managed peer by WireGuard public key and exit")
	rehydrate := flag.Bool("rehydrate", false, "apply SQLite peers onto the live moorlanN device and exit")
	wg := flag.String("wg", "moorlan0", "WireGuard interface (must be moorlan0, moorlan1, …)")
	db := flag.String("db", "", "SQLite path (default /var/lib/moorlan/<wg>.db)")
	privateEndpoint := flag.String("private-endpoint", "", "LAN HTTP control address host:port (required for pair/unpair)")
	homeCIDRs := flag.String("home-cidrs", "", "home IPv4 CIDR(s) for split-tunnel routes when away (required for pair/unpair)")
	publicEndpoint := flag.String("public-endpoint", "", "public WireGuard host:port; overrides STUN discovery (e.g. DDNS)")
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "Usage: moorlan [-wg moorlan0] [-private-endpoint host:port] [-home-cidrs CIDR[,CIDR...]] [--init | --rehydrate | --unpair | --remove <pubkey>] [-public-endpoint host:port]\n\nOptions:")
		flag.PrintDefaults()
	}
	flag.Parse()
	if os.Geteuid() != 0 {
		return fmt.Errorf("must run as root (try: sudo ./moorlan)")
	}
	modes := 0
	if *initialize {
		modes++
	}
	if *unpair {
		modes++
	}
	if *remove != "" {
		modes++
	}
	if *rehydrate {
		modes++
	}
	if modes > 1 {
		return fmt.Errorf("use only one of --init, --rehydrate, --unpair, or --remove")
	}
	if !*initialize && !*unpair && *remove == "" && !*rehydrate && *publicEndpoint != "" {
		if _, _, err := payload.SplitEndpoint(*publicEndpoint); err != nil {
			return err
		}
	}
	release, err := runtime.LockInterface(*wg)
	if err != nil {
		return err
	}
	defer release()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *initialize || *rehydrate || *remove != "" {
		host, err := runtime.DiscoverDevice(*wg, *db)
		if err != nil {
			return err
		}
		if *initialize {
			if err := runtime.InitDatabase(ctx, host); err != nil {
				return err
			}
			fmt.Printf("initialized %s for %s\n", host.StorePath, host.Snap.Name)
			return nil
		}
		assigner, err := runtime.OpenAssigner(ctx, host)
		if err != nil {
			return err
		}
		defer assigner.Close()
		if *rehydrate {
			if err := assigner.Reconcile(ctx); err != nil {
				return err
			}
			fmt.Printf("rehydrated %s from %s\n", host.Snap.Name, host.StorePath)
			return nil
		}
		removed, err := assigner.RemoveManaged(ctx, *remove)
		if err != nil {
			return err
		}
		fmt.Printf("removed %s\n", removed)
		return nil
	}

	var host runtime.Host
	if *unpair {
		host, err = runtime.DiscoverUnpair(*wg, *db, *privateEndpoint, *homeCIDRs)
	} else {
		host, err = runtime.Discover(*wg, *db, *privateEndpoint, *homeCIDRs, *publicEndpoint)
	}
	if err != nil {
		return err
	}
	addr := net.JoinHostPort(host.PairHost, strconv.Itoa(host.PairPort))
	controlURL := "http://" + addr + "/v1/pair"
	assigner, err := runtime.OpenAssigner(ctx, host)
	if err != nil {
		return err
	}
	defer assigner.Close()
	var text string
	var handler http.Handler
	if *unpair {
		text, err = payload.MarshalUnpair(payload.UnpairCard{V: 1, Action: "unpair", ServerPublicKey: host.Snap.PublicKey, UnpairURL: controlURL})
		handler = pair.NewUnpairOnly(assigner)
	} else {
		if host.Endpoint == "" {
			fmt.Println("Discovering public IPv4 via STUN...")
			discovery, cancel := context.WithTimeout(ctx, 5*time.Second)
			host.Endpoint, err = runtime.DiscoverPublicEndpoint(discovery, host.Snap.ListenPort)
			cancel()
			if err != nil {
				return fmt.Errorf("public endpoint discovery failed: %w; supply -public-endpoint host:port", err)
			}
			fmt.Printf("public     %s (STUN IP + WireGuard port; requires matching UDP port forwarding)\n", host.Endpoint)
		} else {
			fmt.Printf("public     %s (explicit)\n", host.Endpoint)
		}
		assigner.Host = host
		text, err = payload.Marshal(payload.Card{V: 1, PairURL: controlURL, ServerPublicKey: host.Snap.PublicKey})
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
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w", addr, err)
	}
	defer listener.Close()
	fmt.Printf("interface  %s\ndatabase   %s\nprivate    %s\nhome CIDRs %s\nservice    %s\n", host.Snap.Name, host.StorePath, addr, host.HomeCIDRLease(), controlURL)
	if err := qr.WriteANSI(os.Stdout, text); err != nil {
		return err
	}
	if *unpair {
		fmt.Println("\nScan with an already-paired device on home Wi‑Fi to unpair.\nDeletion only; the device must provide its saved credential. Ctrl-C stops the service.")
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
