package settings

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// IsTTY reports whether stdin is an interactive terminal.
func IsTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// PromptMissing fills empty required fields from in when interactive.
// Required fields never accept Enter-as-example; the example is hint-only.
func PromptMissing(site *Site, required []string, in io.Reader, out io.Writer) error {
	if !IsTTY() && in == os.Stdin {
		return nil
	}
	reader := bufio.NewReader(in)
	for _, field := range required {
		switch field {
		case "private-endpoint":
			if site.PrivateEndpoint != "" {
				continue
			}
			value, err := promptRequired(reader, out, "LAN HTTP control address (host:port)", "10.10.10.1:8756")
			if err != nil {
				return err
			}
			site.PrivateEndpoint = value
		case "home-cidrs":
			if site.HomeCIDRs != "" {
				continue
			}
			value, err := promptRequired(reader, out, "Home IPv4 CIDR(s), comma-separated", "10.10.0.0/24,10.10.10.0/24")
			if err != nil {
				return err
			}
			site.HomeCIDRs = value
		case "public-endpoint":
			if site.PublicEndpoint != "" {
				continue
			}
			value, err := promptRequired(reader, out, "Public WireGuard endpoint (DDNS or static host:port)", "vpn.example.com:51820")
			if err != nil {
				return err
			}
			site.PublicEndpoint = value
		case "wg":
			if site.WG != "" && site.WG != "wg0" {
				continue
			}
			value, err := promptRequired(reader, out, "WireGuard interface name", "wg0")
			if err != nil {
				return err
			}
			site.WG = value
		}
	}
	return nil
}

func promptRequired(in *bufio.Reader, out io.Writer, label, example string) (string, error) {
	if example != "" {
		fmt.Fprintf(out, "%s\n  example: %s\n> ", label, example)
	} else {
		fmt.Fprintf(out, "%s\n> ", label)
	}
	line, err := in.ReadString('\n')
	if err != nil && len(strings.TrimSpace(line)) == 0 {
		return "", err
	}
	value := strings.TrimSpace(line)
	if value == "" {
		return "", fmt.Errorf("%s is required (type a value; Enter alone does not use the example)", label)
	}
	return value, nil
}
