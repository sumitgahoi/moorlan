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
	pairMode := fs.Bool("pair", false, "print pair QR; enroll devices until idle (2 minutes) or Ctrl-C")
	unpair := fs.Bool("unpair", false, "print unpair QR; accept deletions until idle (2 minutes) or Ctrl-C")
	remove := fs.Bool("remove", false, "remove a managed peer by WireGuard public key and exit")
	peerPublicKey := fs.String("peer-public-key", "", "peer WireGuard public key (with --remove)")
	listPeers := fs.Bool("list-peers", false, "print enrolled peers (label, public key, address) and exit")
	reconcile := fs.Bool("reconcile", false, "apply SQLite peers onto live devices and exit")
	iface := fs.String("interface", "", "WireGuard interface (required if YAML lists multiple; also for --remove)")
	fs.Usage = printUsage
	if err := fs.Parse(os.Args[1:]); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
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
		return fmt.Errorf("use only one of --pair, --unpair, --remove, --list-peers, or --reconcile")
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

	if os.Geteuid() != 0 {
		return fmt.Errorf("must run as root (try: sudo moorlan)")
	}

	site, err := settings.Load()
	if err != nil {
		return err
	}
	storePath := runtime.DefaultStorePath

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
		host, err = runtime.Discover(name, storePath, site.PrivateEndpoint, cfg.HomeNetworks, cfg.PublicEndpoint, cfg.DNSServers, cfg.DNSSearch, cfg.Name)
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
	notify := pair.Notify{
		Paired: func(label, peerKey string) {
			idle.Touch()
			fmt.Fprintf(os.Stderr, "moorlan: paired %q (%s)\n", label, shortKey(peerKey))
		},
		Unpaired: func(peerKey string) {
			idle.Touch()
			fmt.Fprintf(os.Stderr, "moorlan: unpaired (%s)\n", shortKey(peerKey))
		},
	}
	var text string
	var handler http.Handler
	if *unpair {
		text, err = payload.MarshalUnpair(payload.UnpairCard{V: 1, Action: "unpair", ServerPublicKey: host.Snap.PublicKey, UnpairURL: controlURL})
		handler = pair.NewUnpairOnly(assigner, notify)
	} else {
		text, err = payload.Marshal(payload.Card{V: 1, PairURL: controlURL, ServerPublicKey: host.Snap.PublicKey})
		handler = pair.New(assigner, notify)
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
	if err := qr.WriteANSI(os.Stdout, text); err != nil {
		return err
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
		fmt.Fprintf(os.Stderr, "moorlan: idle for 2 minutes; stopping\n")
		return shutdownHTTP()
	case err := <-errCh:
		idle.Stop()
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

func shortKey(key string) string {
	key = strings.TrimSpace(key)
	if len(key) <= 10 {
		return key
	}
	return key[:4] + "…" + key[len(key)-4:]
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
	// Soft-fail per iface inside the run (keep going), but any failure must
	// exit non-zero so systemd Restart=on-failure retries the boot window.
	if failed > 0 {
		return fmt.Errorf("reconcile failed for %d/%d interfaces", failed, len(targets))
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

--pair / --unpair print a QR on stdout and serve LAN HTTP until idle (2 minutes
with no success) or Ctrl-C. Success and errors go to stderr. Omit --interface
when the site YAML lists exactly one WireGuard interface; required when it lists
more than one. --unpair also accepts --interface for a iface that still has
peers in the DB after removal from YAML. --remove always needs --interface.

Site conf: /etc/moorlan/moorlan.yaml (not your wg-quick/networkd device file).
Peers live in SQLite at /var/lib/moorlan/moorlan.db. See server/README.md.
`)
}

func printPeers(ctx context.Context, storePath, ifaceFilter string) error {
	peers, err := runtime.ListPeers(ctx, storePath, ifaceFilter)
	if err != nil {
		return err
	}
	if len(peers) == 0 {
		fmt.Fprintln(os.Stderr, "moorlan: no peers enrolled")
		return nil
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
