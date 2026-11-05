package settings

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	Dir = t.TempDir()
	site := Site{
		WG:              "moorlan0",
		PrivateEndpoint: "10.10.10.1:8756",
		HomeCIDRs:       "10.10.0.0/24,10.10.10.0/24",
		PublicEndpoint:  "vpn.example:51820",
		DNS:             "10.10.10.1",
	}
	if err := Save(site); err != nil {
		t.Fatal(err)
	}
	got, err := Load("moorlan0")
	if err != nil {
		t.Fatal(err)
	}
	if got != site {
		t.Fatalf("got %+v want %+v", got, site)
	}
	raw, err := os.ReadFile(Path("moorlan0"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "peers live in SQLite") {
		t.Fatal("missing peer ownership comment")
	}
	if strings.Contains(string(raw), "unit=") {
		t.Fatal("should not write obsolete unit=")
	}
}

func TestLoadIgnoresObsoleteUnit(t *testing.T) {
	Dir = t.TempDir()
	path := Path("moorlan0")
	if err := os.WriteFile(path, []byte("wg=moorlan0\nunit=networkd\nprivate-endpoint=10.10.10.1:8756\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load("moorlan0")
	if err != nil {
		t.Fatal(err)
	}
	if got.PrivateEndpoint != "10.10.10.1:8756" {
		t.Fatalf("%+v", got)
	}
}

func TestLoadMissingIsEmpty(t *testing.T) {
	Dir = t.TempDir()
	got, err := Load("moorlan1")
	if err != nil {
		t.Fatal(err)
	}
	if got.WG != "moorlan1" || got.PrivateEndpoint != "" {
		t.Fatalf("unexpected %+v", got)
	}
}

func TestLoadRejectsUnknownKeyAndMismatchedWG(t *testing.T) {
	Dir = t.TempDir()
	path := Path("moorlan0")
	if err := os.WriteFile(path, []byte("wg=moorlan0\npeers=bad\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load("moorlan0"); err == nil {
		t.Fatal("unknown key accepted")
	}
	if err := os.WriteFile(path, []byte("wg=moorlan1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load("moorlan0"); err == nil {
		t.Fatal("mismatched wg accepted")
	}
}

func TestApplyFlagsOverrideConf(t *testing.T) {
	conf := Site{WG: "moorlan0", PrivateEndpoint: "10.10.10.1:8756", HomeCIDRs: "10.10.0.0/24", PublicEndpoint: "old.example:51820"}
	flags := Site{WG: "moorlan1", PrivateEndpoint: "10.10.20.1:8756", HomeCIDRs: "10.10.20.0/24", PublicEndpoint: "new.example:51820"}
	got := Apply(conf, flags, map[string]bool{"private-endpoint": true})
	if got.PrivateEndpoint != "10.10.20.1:8756" {
		t.Fatalf("flag did not win: %+v", got)
	}
	if got.HomeCIDRs != "10.10.0.0/24" || got.PublicEndpoint != "old.example:51820" || got.WG != "moorlan0" {
		t.Fatalf("non-explicit fields changed: %+v", got)
	}
	got = Apply(conf, flags, map[string]bool{"wg": true, "public-endpoint": true})
	if got.WG != "moorlan1" || got.PublicEndpoint != "new.example:51820" {
		t.Fatalf("explicit wg/public-endpoint: %+v", got)
	}
}

func TestSaveCreatesDir(t *testing.T) {
	Dir = filepath.Join(t.TempDir(), "etc", "moorlan")
	if err := Save(Site{WG: "moorlan0", PublicEndpoint: "vpn.example:51820"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(Path("moorlan0")); err != nil {
		t.Fatal(err)
	}
}
