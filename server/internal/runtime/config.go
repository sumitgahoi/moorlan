package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"moorlan/internal/iface"
	"moorlan/internal/payload"
)

const blockStart = "### MOORLAN PEERS ###"
const blockEnd = "### END MOORLAN PEERS ###"
const legacyBlockStart = "### PEERDOOR PEERS ###"
const legacyBlockEnd = "### END PEERDOOR PEERS ###"

type configFile struct {
	before, after string
	managed       []iface.Peer
	external      []iface.Peer
	hasBlock      bool
}

// Only the delimited block is replaceable. All bytes outside it are retained.
func readConfig(path string) (configFile, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return configFile{}, err
	}
	if !info.Mode().IsRegular() {
		return configFile{}, fmt.Errorf("configuration must be a regular file")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return configFile{}, err
	}
	return parseConfig(string(raw))
}
func parseConfig(raw string) (configFile, error) {
	start, end, afterEnd := -1, -1, -1
	offset := 0
	for _, line := range strings.SplitAfter(raw, "\n") {
		switch strings.TrimSpace(line) {
		case blockStart, legacyBlockStart:
			if start >= 0 {
				return configFile{}, fmt.Errorf("duplicate Moorlan start marker")
			}
			start = offset
		case blockEnd, legacyBlockEnd:
			if end >= 0 {
				return configFile{}, fmt.Errorf("duplicate Moorlan end marker")
			}
			end = offset
			afterEnd = offset + len(line)
		}
		offset += len(line)
	}
	c := configFile{before: raw}
	if start >= 0 || end >= 0 {
		if start < 0 || end < start {
			return configFile{}, fmt.Errorf("incomplete or reversed Moorlan markers")
		}
		c.before, c.after, c.hasBlock = raw[:start], raw[afterEnd:], true
		var err error
		c.managed, err = configPeers(raw[start:end])
		if err != nil {
			return configFile{}, err
		}
	}
	outside := c.before + c.after
	section, hasInterface := "", false
	for _, line := range strings.Split(outside, "\n") {
		line = configLine(line)
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(line)
			if section == "[interface]" {
				hasInterface = true
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && section == "[interface]" && strings.EqualFold(strings.TrimSpace(key), "SaveConfig") && strings.EqualFold(strings.TrimSpace(value), "true") {
			return configFile{}, fmt.Errorf("disable SaveConfig=true: Moorlan owns its generated peer block")
		}
	}
	if !hasInterface {
		return configFile{}, fmt.Errorf("configuration has no [Interface] section")
	}
	var err error
	c.external, err = configPeers(outside)
	return c, err
}
func configLine(line string) string {
	if i := strings.IndexAny(line, "#;"); i >= 0 {
		line = line[:i]
	}
	return strings.TrimSpace(line)
}
func configPeers(raw string) ([]iface.Peer, error) {
	var peers []iface.Peer
	inPeer := false
	for _, line := range strings.Split(raw, "\n") {
		line = configLine(line)
		if strings.HasPrefix(line, "[") {
			inPeer = strings.EqualFold(line, "[Peer]")
			if inPeer {
				peers = append(peers, iface.Peer{})
			}
			continue
		}
		if !inPeer {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		p := &peers[len(peers)-1]
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "publickey":
			p.PublicKey = strings.TrimSpace(v)
		case "allowedips":
			for _, ip := range strings.Split(v, ",") {
				if ip = strings.TrimSpace(ip); ip != "" {
					p.AllowedIPs = append(p.AllowedIPs, ip)
				}
			}
		}
	}
	seen := map[string]bool{}
	for _, p := range peers {
		if !payload.ValidKey(p.PublicKey) {
			return nil, fmt.Errorf("configuration contains an invalid peer public key")
		}
		if seen[p.PublicKey] {
			return nil, fmt.Errorf("duplicate peer public key in configuration")
		}
		seen[p.PublicKey] = true
	}
	return peers, nil
}
func (c configFile) render(peers []iface.Peer) []byte {
	peers = append([]iface.Peer(nil), peers...)
	sort.Slice(peers, func(i, j int) bool { return peers[i].PublicKey < peers[j].PublicKey })
	var block strings.Builder
	if !c.hasBlock && c.before != "" && !strings.HasSuffix(c.before, "\n") {
		block.WriteString("\n")
	}
	block.WriteString(blockStart + "\n")
	for _, p := range peers {
		block.WriteString("[Peer]\n")
		if p.Label != "" {
			fmt.Fprintf(&block, "# %s\n", p.Label)
		}
		fmt.Fprintf(&block, "PublicKey = %s\nAllowedIPs = %s\n\n", p.PublicKey, strings.Join(p.AllowedIPs, ", "))
	}
	block.WriteString(blockEnd + "\n")
	return []byte(c.before + block.String() + c.after)
}
func writeConfig(path string, raw []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".moorlan-config-*")
	if err != nil {
		return err
	}
	defer func() { _ = file.Close(); _ = os.Remove(file.Name()) }()
	if _, err = file.Write(raw); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
