package settings

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// File holds static Moorlan options normally passed as flags.
type File struct {
	WG               string
	WGConf           string
	PrivateEndpoint  string
	HomeCIDRs        string
	PublicEndpoint   string
}

// Resolve finds and loads a config file.
// If explicit is set, that path is required. Otherwise the first existing of
// ./moorlan.conf and <executable-dir>/moorlan.conf is used. Missing defaults
// are not an error: callers keep using CLI flags / built-in defaults.
func Resolve(explicit string) (path string, cfg File, err error) {
	if explicit != "" {
		cfg, err = Load(explicit)
		if err != nil {
			return "", File{}, err
		}
		return explicit, cfg, nil
	}
	for _, candidate := range defaultPaths() {
		cfg, err = Load(candidate)
		if err == nil {
			return candidate, cfg, nil
		}
		if !os.IsNotExist(err) {
			return "", File{}, fmt.Errorf("%s: %w", candidate, err)
		}
	}
	return "", File{}, nil
}

func defaultPaths() []string {
	out := []string{"moorlan.conf"}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		out = append(out, filepath.Join(filepath.Dir(exe), "moorlan.conf"))
	}
	return out
}

// Load parses a key=value moorlan.conf.
func Load(path string) (File, error) {
	f, err := os.Open(path)
	if err != nil {
		return File{}, err
	}
	defer f.Close()

	var cfg File
	seen := map[string]bool{}
	scanner := bufio.NewScanner(f)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return File{}, fmt.Errorf("%s:%d: expected key=value", path, lineNo)
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if key == "" {
			return File{}, fmt.Errorf("%s:%d: empty key", path, lineNo)
		}
		if seen[key] {
			return File{}, fmt.Errorf("%s:%d: duplicate key %q", path, lineNo, key)
		}
		seen[key] = true
		switch key {
		case "wg":
			cfg.WG = value
		case "wg-conf":
			cfg.WGConf = value
		case "private-endpoint":
			cfg.PrivateEndpoint = value
		case "home-cidrs":
			cfg.HomeCIDRs = value
		case "public-endpoint":
			cfg.PublicEndpoint = value
		default:
			return File{}, fmt.Errorf("%s:%d: unknown key %q", path, lineNo, key)
		}
	}
	if err := scanner.Err(); err != nil {
		return File{}, err
	}
	return cfg, nil
}
