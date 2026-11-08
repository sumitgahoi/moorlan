package settings

import (
	"path/filepath"
	"testing"
)

func TestWriteRoundTrip(t *testing.T) {
	Path = filepath.Join(t.TempDir(), "moorlan.yaml")
	site := CreateDefaultConf("10.10.10.1:8756", map[string]DefaultIface{
		"wg0": {
			Name: "Home", PublicEndpoint: "1.2.3.4:51820",
			HomeNetworks: []string{"10.10.0.0/24"},
			DNSServers:   []string{"10.8.0.1"},
			DNSSearch:    []string{"home.arpa"},
		},
	})
	if err := Write(site); err != nil {
		t.Fatal(err)
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := Validate(got); err != nil {
		t.Fatal(err)
	}
	if got.PrivateEndpoint != site.PrivateEndpoint {
		t.Fatalf("%+v", got)
	}
	iface := got.Interfaces["wg0"]
	if iface.Enabled == nil || *iface.Enabled || iface.Name != "Home" || iface.PublicEndpoint != "1.2.3.4:51820" {
		t.Fatalf("%+v", iface)
	}
}
