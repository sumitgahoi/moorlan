package settings

import "testing"

func TestCreateDefaultConfSetsEveryKey(t *testing.T) {
	site := CreateDefaultConf("10.0.0.5:8756", map[string]DefaultIface{
		"wg0": {
			Name:           "Home",
			PublicEndpoint: "203.0.113.1:51820",
			HomeNetworks:   []string{"10.0.0.0/24"},
			DNSServers:     []string{"10.8.0.1"},
			DNSSearch:      []string{"home.arpa"},
		},
	})
	if site.PrivateEndpoint != "10.0.0.5:8756" {
		t.Fatalf("%s", site.PrivateEndpoint)
	}
	iface := site.Interfaces["wg0"]
	if iface.Enabled == nil || *iface.Enabled {
		t.Fatalf("enabled must be explicit false: %+v", iface.Enabled)
	}
	if iface.Name != "Home" || iface.PublicEndpoint != "203.0.113.1:51820" {
		t.Fatalf("%+v", iface)
	}
	if len(iface.HomeNetworks) != 1 || len(iface.DNSServers) != 1 || len(iface.DNSSearch) != 1 {
		t.Fatalf("%+v", iface)
	}
	if err := Validate(site); err != nil {
		t.Fatal(err)
	}
}
