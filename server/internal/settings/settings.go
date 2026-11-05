// Package settings loads and saves per-interface site settings under /etc/moorlan.
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

// Site is the static configuration for one WireGuard interface.
type Site struct {
	WG              string
	DB              string
	PrivateEndpoint string
	HomeCIDRs       string
	PublicEndpoint  string
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

// Load reads a site conf. A missing file returns an empty Site and nil error.
// Obsolete unit= lines are ignored so older confs still load.
func Load(iface string) (Site, error) {
	path := Path(iface)
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Site{WG: iface}, nil
		}
		return Site{}, err
	}
	defer file.Close()
	site := Site{WG: iface}
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
		case "wg":
			site.WG = value
		case "db":
			site.DB = value
		case "private-endpoint":
			site.PrivateEndpoint = value
		case "home-cidrs":
			site.HomeCIDRs = value
		case "public-endpoint":
			site.PublicEndpoint = value
		case "unit":
			// Obsolete: rehydrate units no longer depend on networkd vs wg-quick.
		default:
			return Site{}, fmt.Errorf("%s:%d: unknown key %q (allowed: wg, db, private-endpoint, home-cidrs, public-endpoint)", path, lineNo, key)
		}
	}
	if err := scanner.Err(); err != nil {
		return Site{}, err
	}
	if site.WG == "" {
		site.WG = iface
	}
	if site.WG != iface {
		return Site{}, fmt.Errorf("%s: wg=%s does not match conf file for %s", path, site.WG, iface)
	}
	return site, nil
}

// Save writes the site conf (0600) under Dir.
func Save(site Site) error {
	if site.WG == "" {
		return fmt.Errorf("wg is required")
	}
	if err := os.MkdirAll(Dir, 0o755); err != nil {
		return err
	}
	var b strings.Builder
	b.WriteString("# Moorlan site settings for " + site.WG + " (not peers; peers live in SQLite).\n")
	fmt.Fprintf(&b, "wg=%s\n", site.WG)
	if site.DB != "" {
		fmt.Fprintf(&b, "db=%s\n", site.DB)
	}
	if site.PrivateEndpoint != "" {
		fmt.Fprintf(&b, "private-endpoint=%s\n", site.PrivateEndpoint)
	}
	if site.HomeCIDRs != "" {
		fmt.Fprintf(&b, "home-cidrs=%s\n", site.HomeCIDRs)
	}
	if site.PublicEndpoint != "" {
		fmt.Fprintf(&b, "public-endpoint=%s\n", site.PublicEndpoint)
	}
	path := Path(site.WG)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Apply overlays explicitly set CLI flags onto conf. Load order: conf → flags.
func Apply(conf, flags Site, explicit map[string]bool) Site {
	out := conf
	if out.WG == "" {
		out.WG = "wg0"
	}
	if explicit["wg"] {
		out.WG = flags.WG
	}
	if explicit["db"] {
		out.DB = flags.DB
	}
	if explicit["private-endpoint"] {
		out.PrivateEndpoint = flags.PrivateEndpoint
	}
	if explicit["home-cidrs"] {
		out.HomeCIDRs = flags.HomeCIDRs
	}
	if explicit["public-endpoint"] {
		out.PublicEndpoint = flags.PublicEndpoint
	}
	return out
}
