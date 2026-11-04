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
	"strings"
	"syscall"
	"time"

	"moorlan/internal/pair"
	"moorlan/internal/payload"
	"moorlan/internal/qr"
	"moorlan/internal/runtime"
	"moorlan/internal/settings"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "moorlan: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfgPath, fileCfg, err := settings.Resolve(peekConfigPath(os.Args[1:]))
	if err != nil {
		return err
	}

	unpair := flag.Bool("unpair", false, "show an unpair QR and accept deletion requests only")
	remove := flag.String("remove", "", "remove a managed peer by public key (or unique label) and exit")
	config := flag.String("config", "", "path to moorlan.conf (default: ./moorlan.conf or next to the binary)")
	wgDefault := "wg0"
	if fileCfg.WG != "" {
		wgDefault = fileCfg.WG
	}
	wg := flag.String("wg", wgDefault, "existing WireGuard interface (Linux)")
	wgConf := flag.String("wg-conf", fileCfg.WGConf, "wg-quick config path (default /etc/wireguard/<wg>.conf)")
	privateEndpoint := flag.String("private-endpoint", fileCfg.PrivateEndpoint, "LAN HTTP control address host:port (required; host must be configured here)")
	homeCIDRs := flag.String("home-cidrs", fileCfg.HomeCIDRs, "home IPv4 CIDR(s) for split-tunnel routes when away (required; comma-separated OK)")
	publicEndpoint := flag.String("public-endpoint", fileCfg.PublicEndpoint, "public WireGuard host:port; overrides STUN discovery (e.g. DDNS)")
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "Usage: moorlan [-config moorlan.conf] [-private-endpoint host:port] [-home-cidrs CIDR[,CIDR...]] [--unpair | --remove label] [-wg wg0] [-public-endpoint host:port]\n\nOptions:")
		for _, advanced := range []bool{false, true} {
			if advanced {
				fmt.Fprintln(flag.CommandLine.Output(), "\nAdvanced options:")
			}
			flag.VisitAll(func(f *flag.Flag) {
				isAdvanced := f.Name != "wg" && f.Name != "public-endpoint" && f.Name != "unpair" && f.Name != "remove" && f.Name != "private-endpoint" && f.Name != "home-cidrs" && f.Name != "config"
				if isAdvanced == advanced {
					fmt.Fprintf(flag.CommandLine.Output(), "  -%s (default %q)\n      %s\n", f.Name, f.DefValue, f.Usage)
				}
			})
		}
	}
	flag.Parse()
	_ = config // registered for usage/-h; path was resolved from argv before Parse
	if *unpair && *remove != "" {
		return fmt.Errorf("use either --unpair or --remove, not both")
	}
	if !*unpair && *remove == "" && *publicEndpoint != "" {
		if _, _, err := payload.SplitEndpoint(*publicEndpoint); err != nil {
			return err
		}
	}
	if cfgPath != "" {
		fmt.Printf("config     %s\n", cfgPath)
	}
	release, err := runtime.LockInterface(*wg)
	if err != nil {
		return err
	}
	defer release()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *remove != "" {
		host, err := runtime.DiscoverUnpair(*wg, *wgConf, *privateEndpoint, *homeCIDRs)
		if err != nil {
			return err
		}
		assigner, err := runtime.OpenAssigner(ctx, host)
		if err != nil {
			return err
		}
		defer assigner.Close()
		removed, err := assigner.RemoveManaged(ctx, *remove)
		if err != nil {
			return err
		}
		fmt.Printf("removed %s\n", removed)
		return nil
	}

	var host runtime.Host
	if *unpair {
		host, err = runtime.DiscoverUnpair(*wg, *wgConf, *privateEndpoint, *homeCIDRs)
	} else {
		host, err = runtime.Discover(*wg, *wgConf, *privateEndpoint, *homeCIDRs, *publicEndpoint)
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
	// Bind before displaying the invitation, so the QR never advertises a failed listener.
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w", addr, err)
	}
	defer listener.Close()
	fmt.Printf("interface  %s\nprivate    %s\nhome CIDRs %s\nservice    %s\n", host.Snap.Name, addr, host.HomeCIDRLease(), controlURL)
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

func peekConfigPath(args []string) string {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "-config" || arg == "--config":
			if i+1 < len(args) {
				return args[i+1]
			}
		case strings.HasPrefix(arg, "-config="):
			return strings.TrimPrefix(arg, "-config=")
		case strings.HasPrefix(arg, "--config="):
			return strings.TrimPrefix(arg, "--config=")
		}
	}
	return ""
}
