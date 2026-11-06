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
	"text/tabwriter"
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
	fs := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	pairMode := fs.Bool("pair", false, "show pairing QR and accept enrollments")
	unpair := fs.Bool("unpair", false, "show unpair QR and accept deletions")
	remove := fs.Bool("remove", false, "remove a managed peer by WireGuard public key and exit")
	peerPublicKey := fs.String("peer-public-key", "", "peer WireGuard public key (with --remove)")
	listPeers := fs.Bool("list-peers", false, "print enrolled peers (label, public key, address) and exit")
	reconcile := fs.Bool("reconcile", false, "apply SQLite peers onto live devices and exit")
	iface := fs.String("interface", "", "WireGuard interface name")
	fs.Usage = printUsage
	if err := fs.Parse(os.Args[1:]); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}

	if os.Geteuid() != 0 {
		return fmt.Errorf("must run as root (try: sudo moorlan)")
	}

	modes := 0
	for _, on := range []bool{*pairMode, *unpair, *reconcile, *listPeers, *remove} {
		if on {
			modes++
		}
	}
	if modes == 0 {
		printUsage()
		return fmt.Errorf("specify --pair, --unpair, --remove, --list-peers, or --reconcile")
	}
	if modes > 1 {
		return fmt.Errorf("use only one primary mode")
	}
	if *peerPublicKey != "" && !*remove {
		return fmt.Errorf("--peer-public-key is only valid with --remove")
	}
	if *remove && *peerPublicKey == "" {
		return fmt.Errorf("--remove requires --peer-public-key <key>")
	}
	if *remove && *iface == "" {
		return fmt.Errorf("--remove requires --interface <iface>")
	}
	if *iface != "" {
		if err := runtime.ValidateInterfaceName(*iface); err != nil {
			return err
		}
	}

	site, err := settings.Load()
	if err != nil {
		return err
	}
	storePath := runtime.StorePath(site.DB)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *listPeers {
		return printPeers(ctx, storePath, *iface)
	}
	if *reconcile {
		return runReconcile(ctx, site, storePath, *iface)
	}
	if *remove {
		return runRemove(ctx, storePath, *iface, *peerPublicKey)
	}

	name, err := resolveSessionInterface(site, storePath, *iface, *unpair)
	if err != nil {
		return err
	}
	release, err := runtime.LockInterface(name)
	if err != nil {
		return err
	}
	defer release()

	var host runtime.Host
	if *unpair {
		host, err = runtime.DiscoverUnpair(name, storePath, site.PrivateEndpoint)
	} else {
		cfg, ok := site.Lookup(name)
		if !ok {
			return fmt.Errorf("interface %s is not listed in %s", name, settings.Path)
		}
		host, err = runtime.Discover(name, storePath, site.PrivateEndpoint, cfg.HomeNetworks, cfg.PublicEndpoint, cfg.DNSServers, cfg.DNSSearch)
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
	if err := assigner.Reconcile(ctx); err != nil {
		return fmt.Errorf("reconcile before serving: %w", err)
	}
	idle := pair.NewIdle(pair.DefaultIdle)
	defer idle.Stop()
	var text string
	var handler http.Handler
	if *unpair {
		text, err = payload.MarshalUnpair(payload.UnpairCard{V: 1, Action: "unpair", ServerPublicKey: host.Snap.PublicKey, UnpairURL: controlURL})
		handler = pair.NewUnpairOnly(assigner, idle.Touch)
	} else {
		fmt.Printf("public     %s\n", host.Endpoint)
		text, err = payload.Marshal(payload.Card{V: 1, PairURL: controlURL, ServerPublicKey: host.Snap.PublicKey})
		handler = pair.New(assigner, idle.Touch)
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
	fmt.Printf("interface  %s\ndatabase   %s\nprivate    %s\n", host.Snap.Name, host.StorePath, addr)
	if len(host.HomeNetworks) > 0 {
		fmt.Printf("home       %s\n", strings.Join(host.HomeNetworks, ","))
	}
	if len(host.DNSServers) > 0 {
		fmt.Printf("dns        %s\n", strings.Join(host.DNSServers, ","))
	}
	if len(host.DNSSearch) > 0 {
		fmt.Printf("dns-search %s\n", strings.Join(host.DNSSearch, ","))
	}
	fmt.Printf("service    %s\n", controlURL)
	if err := qr.WriteANSI(os.Stdout, text); err != nil {
		return err
	}
	if *unpair {
		fmt.Printf("\nScan with an already-paired device on home Wi‑Fi to unpair.\nDeletion only; the device must provide its saved credential.\nStops after %s with no successful unpair (Ctrl-C sooner).\n", pair.DefaultIdle)
	} else {
		fmt.Printf("\nScan on the trusted home LAN to add devices.\nAnyone who can reach this service can enroll while it is running.\nStops after %s with no successful pair (Ctrl-C sooner).\n", pair.DefaultIdle)
	}
	errCh := make(chan error, 1)
	go func() { errCh <- server.Serve(listener) }()
	shutdownHTTP := func() error {
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return err
		}
		return nil
	}
	select {
	case <-ctx.Done():
		idle.Stop()
		return shutdownHTTP()
	case <-idle.Done():
		fmt.Printf("\nmoorlan: idle for %s; stopping\n", pair.DefaultIdle)
		return shutdownHTTP()
	case err := <-errCh:
		idle.Stop()
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

func resolveSessionInterface(site settings.Site, storePath, ifaceFlag string, unpairOnly bool) (string, error) {
	yamlNames := site.InterfaceNames()
	if ifaceFlag != "" {
		if _, ok := site.Lookup(ifaceFlag); ok {
			return ifaceFlag, nil
		}
		if !unpairOnly {
			return "", fmt.Errorf("interface %s is not listed in %s", ifaceFlag, settings.Path)
		}
		dbNames, err := runtime.ListDBInterfaces(storePath)
		if err != nil {
			return "", err
		}
		for _, name := range dbNames {
			if name == ifaceFlag {
				return ifaceFlag, nil
			}
		}
		return "", fmt.Errorf("interface %s is not in %s or the peer database", ifaceFlag, settings.Path)
	}
	if len(yamlNames) == 1 {
		return yamlNames[0], nil
	}
	if len(yamlNames) == 0 {
		if unpairOnly {
			return "", fmt.Errorf("--interface is required when no interfaces are listed in %s", settings.Path)
		}
		return "", fmt.Errorf("no interfaces listed in %s", settings.Path)
	}
	return "", fmt.Errorf("--interface is required when multiple interfaces are configured (%s)", strings.Join(yamlNames, ", "))
}

func runReconcile(ctx context.Context, site settings.Site, storePath, ifaceFlag string) error {
	dbNames, err := runtime.ListDBInterfaces(storePath)
	if err != nil {
		return err
	}
	targets, err := runtime.ReconcileTargets(site.InterfaceNames(), dbNames, ifaceFlag)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		fmt.Printf("nothing to reconcile (no interfaces in %s or %s)\n", settings.Path, storePath)
		return nil
	}
	var failed int
	for _, name := range targets {
		if err := reconcileOne(ctx, storePath, name); err != nil {
			failed++
			fmt.Fprintf(os.Stderr, "moorlan: reconcile %s: %v\n", name, err)
			continue
		}
		fmt.Printf("reconciled %s from %s\n", name, storePath)
	}
	if failed == len(targets) {
		return fmt.Errorf("reconcile failed for every interface (%d)", failed)
	}
	return nil
}

func reconcileOne(ctx context.Context, storePath, name string) error {
	if err := runtime.ValidateInterfaceName(name); err != nil {
		return err
	}
	release, err := runtime.LockInterface(name)
	if err != nil {
		return err
	}
	defer release()
	host, err := runtime.DiscoverDevice(name, storePath)
	if err != nil {
		return err
	}
	assigner, err := runtime.OpenAssigner(ctx, host)
	if err != nil {
		return err
	}
	defer assigner.Close()
	return assigner.Reconcile(ctx)
}

func runRemove(ctx context.Context, storePath, iface, peerPublicKey string) error {
	release, err := runtime.LockInterface(iface)
	if err != nil {
		return err
	}
	defer release()
	host, err := runtime.DiscoverDevice(iface, storePath)
	if err != nil {
		return err
	}
	assigner, err := runtime.OpenAssigner(ctx, host)
	if err != nil {
		return err
	}
	defer assigner.Close()
	removed, err := assigner.RemoveManaged(ctx, peerPublicKey)
	if err != nil {
		return err
	}
	fmt.Printf("removed peer %s\n", removed)
	return nil
}

func printUsage() {
	fmt.Fprint(os.Stderr, `Usage:
  moorlan --pair [--interface <iface>]
  moorlan --unpair [--interface <iface>]
  moorlan --list-peers [--interface <iface>]
  moorlan --remove --interface <iface> --peer-public-key <key>
  moorlan --reconcile [--interface <iface>]

Install the release binary to /usr/local/bin/moorlan and the example YAML to
/usr/share/moorlan/moorlan.yaml.example (see server/README.md).
Site conf /etc/moorlan/moorlan.yaml is NOT your wg-quick/networkd device file.
Peers live in SQLite. Site settings come from the YAML file only.
`)
}

func printPeers(ctx context.Context, storePath, ifaceFilter string) error {
	peers, err := runtime.ListPeers(ctx, storePath, ifaceFilter)
	if err != nil {
		return err
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "INTERFACE\tLABEL\tPUBLIC_KEY\tADDRESS")
	for _, p := range peers {
		label := p.Label
		if label == "" {
			label = "-"
		}
		addr := p.Address
		if addr == "" {
			addr = "-"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", p.Interface, label, p.PublicKey, addr)
	}
	return w.Flush()
}
