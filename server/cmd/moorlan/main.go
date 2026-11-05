package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
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
	"moorlan/systemd"
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
	removePeer := fs.String("remove-peer", "", "remove a managed peer by WireGuard public key and exit")
	listPeers := fs.Bool("list-peers", false, "print enrolled peers (label, public key, address) and exit")
	rehydrate := fs.Bool("rehydrate", false, "apply SQLite peers onto the live device and exit")
	addIface := fs.String("add-interface", "", "add WireGuard iface: conf, DB, rehydrate unit")
	removeIface := fs.String("remove-interface", "", "remove Moorlan conf, empty peer DB, and rehydrate unit; keep the host device")
	wg := fs.String("wg", "wg0", "WireGuard interface (default wg0)")
	db := fs.String("db", "", "SQLite path (default /var/lib/moorlan/<wg>.db)")
	privateEndpoint := fs.String("private-endpoint", "", "override conf: LAN HTTP host:port")
	homeCIDRs := fs.String("home-cidrs", "", "override conf: home IPv4 CIDR(s)")
	publicEndpoint := fs.String("public-endpoint", "", "override conf: public WireGuard host:port")
	fs.Usage = printUsage
	if err := fs.Parse(os.Args[1:]); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	explicit := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { explicit[f.Name] = true })

	if os.Geteuid() != 0 {
		return fmt.Errorf("must run as root (try: sudo moorlan)")
	}

	modes := 0
	for _, on := range []bool{*pairMode, *unpair, *rehydrate, *listPeers} {
		if on {
			modes++
		}
	}
	if *removePeer != "" {
		modes++
	}
	if *addIface != "" {
		modes++
	}
	if *removeIface != "" {
		modes++
	}
	if modes == 0 {
		printUsage()
		return fmt.Errorf("specify --pair, --unpair, --remove-peer, --list-peers, --add-interface, --remove-interface, or --rehydrate")
	}
	if modes > 1 {
		return fmt.Errorf("use only one primary mode")
	}

	if *addIface != "" {
		return runAddInterface(*addIface, *db, *privateEndpoint, *homeCIDRs, *publicEndpoint)
	}
	if *removeIface != "" {
		return runRemoveInterface(*removeIface)
	}

	site, err := resolveSite(*wg, *db, *privateEndpoint, *homeCIDRs, *publicEndpoint, explicit)
	if err != nil {
		return err
	}
	if err := runtime.ValidateInterfaceName(site.WG); err != nil {
		return err
	}

	if *pairMode || *unpair || *listPeers {
		if !settings.Exists(site.WG) {
			hint := fmt.Sprintf("sudo moorlan --add-interface %s", site.WG)
			if names, err := settings.ListIfaceNames(); err == nil && len(names) > 0 {
				hint = fmt.Sprintf("added interfaces: %s; pass -wg <name> or run --add-interface", strings.Join(names, ", "))
			}
			return fmt.Errorf("interface %s not added (%s)", site.WG, hint)
		}
	}

	release, err := runtime.LockInterface(site.WG)
	if err != nil {
		return err
	}
	defer release()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *rehydrate || *removePeer != "" || *listPeers {
		host, err := runtime.DiscoverDevice(site.WG, site.DB)
		if err != nil {
			return err
		}
		assigner, err := runtime.OpenAssigner(ctx, host)
		if err != nil {
			return err
		}
		defer assigner.Close()
		if *listPeers {
			return printPeers(ctx, assigner)
		}
		if err := assigner.Reconcile(ctx); err != nil {
			return err
		}
		if *rehydrate {
			fmt.Printf("rehydrated %s from %s\n", host.Snap.Name, host.StorePath)
			return nil
		}
		removed, err := assigner.RemoveManaged(ctx, *removePeer)
		if err != nil {
			return err
		}
		fmt.Printf("removed peer %s\n", removed)
		return nil
	}

	if err := requirePairSettings(&site, *unpair); err != nil {
		return err
	}

	var host runtime.Host
	if *unpair {
		host, err = runtime.DiscoverUnpair(site.WG, site.DB, site.PrivateEndpoint)
	} else {
		host, err = runtime.Discover(site.WG, site.DB, site.PrivateEndpoint, site.HomeCIDRs, site.PublicEndpoint)
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
	fmt.Printf("interface  %s\ndatabase   %s\nprivate    %s\nhome CIDRs %s\nservice    %s\n", host.Snap.Name, host.StorePath, addr, host.HomeCIDRLease(), controlURL)
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

func printUsage() {
	fmt.Fprint(os.Stderr, `Usage:
  moorlan --add-interface <iface>     # new conf + DB + rehydrate unit (greenfield)
  moorlan --remove-interface <iface>  # unit + conf + empty DB (refuses if peers remain)
  moorlan --pair | --unpair | --remove-peer <pubkey> | --list-peers | --rehydrate

Install the release binary to /usr/local/bin/moorlan (see server/README.md).
Site conf /etc/moorlan/<iface>.conf is NOT your wg-quick/networkd device file.
Peers live in SQLite. Default -wg is wg0 when only one name is needed.

  -wg                  WireGuard interface (default wg0; auto-picks sole conf if present)
  -db                  SQLite path override
  -private-endpoint    LAN HTTP host:port (required for --add-interface / --pair)
  -home-cidrs          home IPv4 CIDR(s) (required for --add-interface / --pair)
  -public-endpoint     public WireGuard DDNS or static host:port (required for --add-interface / --pair)
`)
}

func printPeers(ctx context.Context, assigner *runtime.Assigner) error {
	peers, err := assigner.List(ctx)
	if err != nil {
		return err
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "LABEL\tPUBLIC_KEY\tADDRESS")
	for _, p := range peers {
		label := p.Label
		if label == "" {
			label = "-"
		}
		addr := "-"
		if len(p.AllowedIPs) > 0 {
			addr = p.AllowedIPs[0]
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", label, p.PublicKey, addr)
	}
	return w.Flush()
}

func resolveSite(wg, db, privateEndpoint, homeCIDRs, publicEndpoint string, explicit map[string]bool) (settings.Site, error) {
	iface := "wg0"
	if explicit["wg"] {
		iface = wg
	} else if !settings.Exists(iface) {
		names, err := settings.ListIfaceNames()
		if err != nil {
			return settings.Site{}, err
		}
		switch len(names) {
		case 0:
			// keep wg0; later modes report "not added"
		case 1:
			iface = names[0]
		default:
			return settings.Site{}, fmt.Errorf("multiple interfaces configured (%s); pass -wg <name>", strings.Join(names, ", "))
		}
	}
	conf, err := settings.Load(iface)
	if err != nil {
		return settings.Site{}, err
	}
	flags := settings.Site{
		WG:              wg,
		DB:              db,
		PrivateEndpoint: privateEndpoint,
		HomeCIDRs:       homeCIDRs,
		PublicEndpoint:  publicEndpoint,
	}
	site := settings.Apply(conf, flags, explicit)
	if !explicit["wg"] {
		site.WG = iface
	}
	return site, nil
}

func requirePairSettings(site *settings.Site, unpairOnly bool) error {
	if site.PrivateEndpoint == "" {
		return fmt.Errorf("private-endpoint missing in %s", settings.Path(site.WG))
	}
	if unpairOnly {
		return nil
	}
	if site.HomeCIDRs == "" {
		return fmt.Errorf("home-cidrs missing in %s", settings.Path(site.WG))
	}
	if site.PublicEndpoint == "" {
		return fmt.Errorf("public-endpoint missing in %s (DDNS or static host:port)", settings.Path(site.WG))
	}
	if _, _, err := payload.SplitEndpoint(site.PublicEndpoint); err != nil {
		return fmt.Errorf("public-endpoint in %s: %w", settings.Path(site.WG), err)
	}
	return nil
}

func runAddInterface(iface, db, privateEndpoint, homeCIDRs, publicEndpoint string) error {
	if err := runtime.ValidateInterfaceName(iface); err != nil {
		return err
	}
	release, err := runtime.LockInterface(iface)
	if err != nil {
		return err
	}

	storePath := db
	if storePath == "" {
		storePath = runtime.DefaultStorePath(iface)
	}
	unitPath := systemd.UnitPath(iface)
	if settings.Exists(iface) {
		release()
		return fmt.Errorf("interface %s already added (%s); redo with: sudo moorlan --remove-interface %s", iface, settings.Path(iface), iface)
	}
	if _, err := os.Stat(storePath); err == nil {
		release()
		return fmt.Errorf("database %s already exists; remove peers then: sudo moorlan --remove-interface %s", storePath, iface)
	} else if !os.IsNotExist(err) {
		release()
		return err
	}
	if _, err := os.Stat(unitPath); err == nil {
		release()
		return fmt.Errorf("rehydrate unit %s already exists; redo with: sudo moorlan --remove-interface %s", unitPath, iface)
	} else if !os.IsNotExist(err) {
		release()
		return err
	}

	site := settings.Site{WG: iface, DB: storePath, PrivateEndpoint: privateEndpoint, HomeCIDRs: homeCIDRs, PublicEndpoint: publicEndpoint}
	if site.PrivateEndpoint == "" || site.HomeCIDRs == "" || site.PublicEndpoint == "" {
		release()
		return fmt.Errorf(`--add-interface requires flags (values are written to %s), for example:
  sudo moorlan --add-interface %s \
    -private-endpoint 10.10.10.1:8756 \
    -home-cidrs 10.10.0.0/24,10.10.10.0/24 \
    -public-endpoint vpn.example.com:51820`, settings.Path(iface), iface)
	}
	if _, _, err := payload.SplitEndpoint(site.PublicEndpoint); err != nil {
		release()
		return fmt.Errorf("public-endpoint: %w", err)
	}

	host, err := runtime.Discover(iface, storePath, site.PrivateEndpoint, site.HomeCIDRs, site.PublicEndpoint)
	if err != nil {
		release()
		return fmt.Errorf("cannot add interface: %w", err)
	}

	rollback := func() {
		_ = os.Remove(unitPath)
		_ = os.Remove(settings.Path(iface))
		_ = os.Remove(storePath)
	}

	if err := settings.Save(site); err != nil {
		release()
		return err
	}
	fmt.Printf("wrote %s (site flags only; not a wg-quick/networkd peer file)\n", settings.Path(iface))
	fmt.Printf("  private-endpoint=%s\n  home-cidrs=%s\n  public-endpoint=%s\n",
		site.PrivateEndpoint, site.HomeCIDRs, site.PublicEndpoint)

	ctx := context.Background()
	if err := runtime.InitDatabase(ctx, host); err != nil {
		rollback()
		release()
		return err
	}
	fmt.Printf("initialized %s\n", storePath)

	// Write the unit while locked, but release before enable --now so rehydrate can take the lock.
	if err := installUnit(iface); err != nil {
		rollback()
		release()
		return err
	}
	release()

	unitName := filepath.Base(unitPath)
	if err := systemctl("enable", "--now", unitName); err != nil {
		_ = systemctl("disable", "--now", unitName)
		rollback()
		_ = systemctl("daemon-reload")
		return err
	}
	fmt.Printf("enabled %s\n", unitName)
	fmt.Printf("next: sudo moorlan --pair -wg %s\n", iface)
	return nil
}

func runRemoveInterface(iface string) error {
	if err := runtime.ValidateInterfaceName(iface); err != nil {
		return err
	}
	release, err := runtime.LockInterface(iface)
	if err != nil {
		return err
	}
	defer release()

	storePath := runtime.DefaultStorePath(iface)
	if settings.Exists(iface) {
		site, err := settings.Load(iface)
		if err != nil {
			return err
		}
		if site.DB != "" {
			storePath = site.DB
		}
	}
	if _, err := os.Stat(storePath); err == nil {
		peers, pending, err := runtime.CountPeersAndPending(storePath)
		if err != nil {
			return err
		}
		if peers+pending > 0 {
			return fmt.Errorf("refusing --remove-interface: database still has %d peer(s) and %d pending removal(s); unpair or --remove-peer first", peers, pending)
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	unitPath := systemd.UnitPath(iface)
	if _, err := os.Stat(unitPath); err == nil {
		if err := systemctl("disable", "--now", filepath.Base(unitPath)); err != nil {
			return err
		}
		if err := os.Remove(unitPath); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	fmt.Printf("removed unit %s\n", unitPath)

	if err := os.Remove(storePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Remove(settings.Path(iface)); err != nil && !os.IsNotExist(err) {
		return err
	}
	fmt.Printf("removed %s\nremoved %s\n", storePath, settings.Path(iface))
	fmt.Printf("interface %s removed from Moorlan; host WireGuard device unchanged\n", iface)
	return nil
}

func systemctl(args ...string) error {
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			return fmt.Errorf("systemctl %s: %w (see journalctl -u %s)", strings.Join(args, " "), err, lastUnitArg(args))
		}
		return fmt.Errorf("systemctl %s: %w\n%s", strings.Join(args, " "), err, msg)
	}
	return nil
}

func lastUnitArg(args []string) string {
	for i := len(args) - 1; i >= 0; i-- {
		if strings.HasSuffix(args[i], ".service") {
			return args[i]
		}
	}
	if len(args) > 0 {
		return args[len(args)-1]
	}
	return "moorlan-rehydrate-*.service"
}

func installUnit(iface string) error {
	text, err := systemd.Render(iface)
	if err != nil {
		return err
	}
	path := systemd.UnitPath(iface)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s\n", path)
	return systemctl("daemon-reload")
}
