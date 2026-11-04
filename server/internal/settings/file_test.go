package settings

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "moorlan.conf")
	content := `
# comment
private-endpoint = 10.10.10.1:8756
home-cidrs=10.10.0.0/16
public-endpoint = home.example.com:51820
wg = wg0
wg-conf = /etc/wireguard/wg0.conf
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PrivateEndpoint != "10.10.10.1:8756" || cfg.HomeCIDRs != "10.10.0.0/16" || cfg.PublicEndpoint != "home.example.com:51820" {
		t.Fatalf("%+v", cfg)
	}
	if cfg.WG != "wg0" || cfg.WGConf != "/etc/wireguard/wg0.conf" {
		t.Fatalf("%+v", cfg)
	}
}

func TestLoadRejectsUnknownAndDuplicate(t *testing.T) {
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.conf")
	if err := os.WriteFile(bad, []byte("foo = bar\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(bad); err == nil {
		t.Fatal("unknown key accepted")
	}
	dup := filepath.Join(dir, "dup.conf")
	if err := os.WriteFile(dup, []byte("wg=wg0\nwg=wg1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dup); err == nil {
		t.Fatal("duplicate key accepted")
	}
}

func TestResolveExplicitMissing(t *testing.T) {
	if _, _, err := Resolve(filepath.Join(t.TempDir(), "missing.conf")); err == nil {
		t.Fatal("missing explicit config accepted")
	}
}

func TestResolveOptionalMissing(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(wd) })
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	path, cfg, err := Resolve("")
	if err != nil || path != "" || cfg != (File{}) {
		t.Fatalf("path=%q cfg=%+v err=%v", path, cfg, err)
	}
}
