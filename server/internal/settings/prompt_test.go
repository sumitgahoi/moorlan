package settings

import (
	"strings"
	"testing"
)

func TestPromptMissingRequiresTypedValues(t *testing.T) {
	site := Site{WG: "wg0"}
	in := strings.NewReader("\n")
	var out strings.Builder
	err := PromptMissing(&site, []string{"private-endpoint"}, in, &out)
	if err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("empty enter should not accept example: %v", err)
	}
}

func TestPromptMissingFillsTypedFields(t *testing.T) {
	site := Site{WG: "wg0"}
	in := strings.NewReader("10.10.10.1:8756\n10.10.0.0/24\nvpn.example:51820\n")
	var out strings.Builder
	if err := PromptMissing(&site, []string{"private-endpoint", "home-cidrs", "public-endpoint"}, in, &out); err != nil {
		t.Fatal(err)
	}
	if site.PrivateEndpoint != "10.10.10.1:8756" || site.HomeCIDRs != "10.10.0.0/24" || site.PublicEndpoint != "vpn.example:51820" {
		t.Fatalf("unexpected %+v", site)
	}
	if !strings.Contains(out.String(), "example:") {
		t.Fatal("expected example hint in prompt output")
	}
	if !strings.Contains(out.String(), "DDNS") {
		t.Fatal("expected DDNS hint for public endpoint")
	}
}
