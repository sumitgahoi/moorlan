package runtime

import (
	"context"
	"os"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
	"peerdoor/internal/iface"
)

func TestRenderPreservesUnmanagedBytesAndIsDeterministic(t *testing.T) {
	before := "[Interface]\r\nPrivateKey = unchanged\r\n# administrator comment\r\n"
	after := "\n[Peer]\nPublicKey = " + wgtypes.Key{9}.String() + "\nAllowedIPs = 192.168.50.0/24\n# tail without newline"
	raw := before + blockStart + "\n" + blockEnd + "\n" + after
	config, err := parseConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	peers := []iface.Peer{{PublicKey: wgtypes.Key{4}.String(), AllowedIPs: []string{"10.8.0.3/32"}}, {PublicKey: wgtypes.Key{1}.String(), AllowedIPs: []string{"10.8.0.2/32"}}}
	rendered := string(config.render(peers))
	if !strings.HasPrefix(rendered, before) || !strings.HasSuffix(rendered, after) {
		t.Fatal("changed unmanaged bytes")
	}
	peers[0], peers[1] = peers[1], peers[0]
	if string(config.render(peers)) != rendered {
		t.Fatal("nondeterministic rendering")
	}
	again, err := parseConfig(rendered)
	if err != nil || string(again.render(peers)) != rendered {
		t.Fatal("repeated rendering changed configuration")
	}
}
func TestMalformedMarkersAndSaveConfigAreRejected(t *testing.T) {
	for _, tail := range []string{blockStart + "\n", blockEnd + "\n", blockEnd + "\n" + blockStart + "\n", blockStart + "\n" + blockStart + "\n" + blockEnd + "\n", "SaveConfig = true\n"} {
		if _, err := parseConfig("[Interface]\n" + tail); err == nil {
			t.Fatalf("accepted %q", tail)
		}
	}
}
func TestSavedConfigIsPrivateAndMissingConfigIsNotReconstructed(t *testing.T) {
	a, _, key := fixture(t)
	if _, err := a.Assign(context.Background(), key.String()); err != nil {
		t.Fatal(err)
	}
	info, _ := os.Stat(a.Host.ConfPath)
	if info.Mode().Perm() != 0600 {
		t.Fatal(info.Mode())
	}
	info, _ = os.Stat(a.Host.ConfPath + ".peerdoor.db")
	if info.Mode().Perm() != 0600 {
		t.Fatal(info.Mode())
	}
	os.Remove(a.Host.ConfPath)
	if err := a.Reconcile(context.Background()); err == nil {
		t.Fatal("recreated missing interface configuration")
	}
}
