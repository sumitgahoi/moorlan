// Package settings loads per-interface site settings under /etc/moorlan.
// The file holds only static host parameters (not peers or device keys).
package settings

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Dir is the directory for per-interface site conf files. Tests may override it.
var Dir = "/etc/moorlan"

// ExamplePath is where the packaged example conf is installed.
const ExamplePath = "/usr/share/moorlan/moorlan.conf.example"

// Site is the static configuration for one WireGuard interface.
type Site struct {
	Interface       string
	DB              string
	PrivateEndpoint string
	HomeNetworks    string
	PublicEndpoint  string
	DNSServers      string
	DNSSearch       string
}

// Path returns /etc/moorlan/<iface>.conf.
func Path(iface string) string {
	return filepath.Join(Dir, iface+".conf")
}

// Exists reports whether a site conf file is present for iface.
func Exists(iface string) bool {
	_, err := os.Stat(Path(iface))
	return err == nil
}

// ListIfaceNames returns iface names that have a conf under Dir.
func ListIfaceNames() ([]string, error) {
	entries, err := os.ReadDir(Dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".conf") {
			continue
		}
		names = append(names, strings.TrimSuffix(name, ".conf"))
	}
	sort.Strings(names)
	return names, nil
}

// Load reads and validates a site conf. Missing file is an error that names
// the expected path and the shipped example to copy.
func Load(iface string) (Site, error) {
	path := Path(iface)
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Site{}, fmt.Errorf("site conf %s not found; copy %s and edit it first", path, ExamplePath)
		}
		return Site{}, err
	}
	defer file.Close()
	site := Site{Interface: iface}
	scanner := bufio.NewScanner(file)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return Site{}, fmt.Errorf("%s:%d: expected key=value", path, lineNo)
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		switch key {
		case "interface":
			site.Interface = value
		case "db":
			site.DB = value
		case "private-endpoint":
			site.PrivateEndpoint = value
		case "home-networks":
			site.HomeNetworks = value
		case "public-endpoint":
			site.PublicEndpoint = value
		case "dns-servers":
			site.DNSServers = value
		case "dns-search":
			site.DNSSearch = value
		default:
			return Site{}, fmt.Errorf("%s:%d: unknown key %q (allowed: interface, db, private-endpoint, public-endpoint, home-networks, dns-servers, dns-search)", path, lineNo, key)
		}
	}
	if err := scanner.Err(); err != nil {
		return Site{}, err
	}
	if site.Interface == "" {
		site.Interface = iface
	}
	if site.Interface != iface {
		return Site{}, fmt.Errorf("%s: interface=%s does not match conf file for %s", path, site.Interface, iface)
	}
	return site, nil
}
