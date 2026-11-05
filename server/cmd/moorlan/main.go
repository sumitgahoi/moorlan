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
	remove := fs.Bool("remove", false, "remove a managed peer by WireGuard public key and exit")
	peerPublicKey := fs.String("peer-public-key", "", "peer WireGuard public key (with --remove)")
	listPeers := fs.Bool("list-peers", false, "print enrolled peers (label, public key, address) and exit")
	reconcile := fs.Bool("reconcile", false, "apply SQLite peers onto the live device and exit")
	addIface := fs.String("add-interface", "", "validate site conf; create DB + reconcile unit")
	removeIface := fs.String("remove-interface", "", "remove Moorlan conf, empty peer DB, and reconcile unit; keep the host device")
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
	if *addIface != "" {
		modes++
	}
	if *removeIface != "" {
		modes++
	}
	if modes == 0 {
		printUsage()
		return fmt.Errorf("specify --pair, --unpair, --remove, --list-peers, --add-interface, --remove-interface, or --reconcile")
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

	if *addIface != "" {
		return runAddInterface(*addIface)
	}
	if *removeIface != "" {
		return runRemoveInterface(*removeIface)
	}

	if *iface == "" {
		return fmt.Errorf("--interface <iface> is required")
	}
	if err := runtime.ValidateInterfaceName(*iface); err != nil {
		return err
	}

	site, err := settings.Load(*iface)
	if err != nil {
		return enrichIfaceError(*iface, err)
	}
	if site.DB == "" {
		site.DB = runtime.DefaultStorePath(site.Interface)
	}
	if _, err := os.Stat(site.DB); err != nil {
		if os.IsNotExist(err) {
			return enrichIfaceError(*iface, fmt.Errorf("interface %s not added (database %s missing; run: sudo moorlan --add-interface %s)", site.Interface, site.DB, site.Interface))
		}
		return err
	}

	release, err := runtime.LockInterface(site.Interface)
	if err != nil {
		return err
	}
	defer release()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *reconcile || *remove || *listPeers {
		host, err := runtime.DiscoverDevice(site.Interface, site.DB)
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
		if *reconcile {
			if err := assigner.Reconcile(ctx); err != nil {
				return err
			}
			fmt.Printf("reconciled %s from %s\n", host.Snap.Name, host.StorePath)
			return nil
		}
		removed, err := assigner.RemoveManaged(ctx, *peerPublicKey)
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
		host, err = runtime.DiscoverUnpair(site.Interface, site.DB, site.PrivateEndpoint)
	} else {
		host, err = runtime.Discover(site.Interface, site.DB, site.PrivateEndpoint, site.HomeNetworks, site.PublicEndpoint, site.DNSServers, site.DNSSearch)
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

func enrichIfaceError(want string, err error) error {
	names, listErr := settings.ListIfaceNames()
	if listErr != nil || len(names) == 0 {
		return err
	}
	var others []string
	for _, name := range names {
		if name != want {
			others = append(others, name)
		}
	}
	if len(others) == 0 {
		return fmt.Errorf("%w (configured: %s)", err, strings.Join(names, ", "))
	}
	return fmt.Errorf("%w (other configured interfaces: %s)", err, strings.Join(others, ", "))
}

func printUsage() {
	fmt.Fprint(os.Stderr, `Usage:
  moorlan --add-interface <iface>     # validate /etc/moorlan/<iface>.conf; create DB + reconcile unit
  moorlan --remove-interface <iface>  # unit + conf + empty DB (refuses if peers remain)
  moorlan --pair --interface <iface>
  moorlan --unpair --interface <iface>
  moorlan --list-peers --interface <iface>
  moorlan --remove --interface <iface> --peer-public-key <key>
  moorlan --reconcile --interface <iface>

Install the release binary to /usr/local/bin/moorlan and the example conf to
/usr/share/moorlan/moorlan.conf.example (see server/README.md).
Site conf /etc/moorlan/<iface>.conf is NOT your wg-quick/networkd device file.
Peers live in SQLite. Site settings come from the conf file only.
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

func requirePairSettings(site *settings.Site, unpairOnly bool) error {
	if site.PrivateEndpoint == "" {
		return fmt.Errorf("private-endpoint missing in %s", settings.Path(site.Interface))
	}
	if unpairOnly {
		return nil
	}
	if site.HomeNetworks == "" {
		return fmt.Errorf("home-networks missing in %s", settings.Path(site.Interface))
	}
	if site.PublicEndpoint == "" {
		return fmt.Errorf("public-endpoint missing in %s (DDNS or static host:port)", settings.Path(site.Interface))
	}
	if _, _, err := payload.SplitEndpoint(site.PublicEndpoint); err != nil {
		return fmt.Errorf("public-endpoint in %s: %w", settings.Path(site.Interface), err)
	}
	if site.DNSServers == "" {
		return fmt.Errorf("dns-servers missing in %s", settings.Path(site.Interface))
	}
	return nil
}

func runAddInterface(iface string) error {
	if err := runtime.ValidateInterfaceName(iface); err != nil {
		return err
	}
	release, err := runtime.LockInterface(iface)
	if err != nil {
		return err
	}

	site, err := settings.Load(iface)
	if err != nil {
		release()
		return err
	}
	storePath := site.DB
	if storePath == "" {
		storePath = runtime.DefaultStorePath(iface)
		site.DB = storePath
	}
	unitPath := systemd.UnitPath(iface)

	if _, err := os.Stat(storePath); err == nil {
		release()
		return fmt.Errorf("database %s already exists; remove peers then: sudo moorlan --remove-interface %s", storePath, iface)
	} else if !os.IsNotExist(err) {
		release()
		return err
	}
	if _, err := os.Stat(unitPath); err == nil {
		release()
		return fmt.Errorf("reconcile unit %s already exists; redo with: sudo moorlan --remove-interface %s", unitPath, iface)
	} else if !os.IsNotExist(err) {
		release()
		return err
	}

	if site.PrivateEndpoint == "" || site.HomeNetworks == "" || site.PublicEndpoint == "" || site.DNSServers == "" {
		release()
		return fmt.Errorf("site conf %s must set private-endpoint, home-networks, public-endpoint, and dns-servers (see %s)", settings.Path(iface), settings.ExamplePath)
	}
	if _, _, err := payload.SplitEndpoint(site.PublicEndpoint); err != nil {
		release()
		return fmt.Errorf("public-endpoint: %w", err)
	}

	host, err := runtime.Discover(iface, storePath, site.PrivateEndpoint, site.HomeNetworks, site.PublicEndpoint, site.DNSServers, site.DNSSearch)
	if err != nil {
		release()
		return fmt.Errorf("cannot add interface: %w", err)
	}

	// Partial failure rolls back DB and unit only — never the operator site conf.
	rollback := func() {
		_ = os.Remove(unitPath)
		_ = os.Remove(storePath)
	}

	ctx := context.Background()
	if err := runtime.InitDatabase(ctx, host); err != nil {
		rollback()
		release()
		return err
	}
	fmt.Printf("initialized %s\n", storePath)
	fmt.Printf("using site conf %s (unchanged)\n", settings.Path(iface))

	// Write the unit while locked, but release before enable --now so reconcile can take the lock.
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
	fmt.Printf("next: sudo moorlan --pair --interface %s\n", iface)
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
		peers, err := runtime.CountPeers(storePath)
		if err != nil {
			return err
		}
		if peers > 0 {
			return fmt.Errorf("refusing --remove-interface: database still has %d peer(s); unpair or --remove first", peers)
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
	return "moorlan-reconcile-*.service"
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
