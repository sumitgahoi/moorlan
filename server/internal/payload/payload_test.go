package payload

import (
	"strings"
	"testing"
)

func TestCardRoundTrip(t *testing.T) {
	card := Card{V: 3, PairURL: "http://192.168.1.10:8756/v1/pair", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}
	text, err := Marshal(card)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Parse(text)
	if err != nil || got != card {
		t.Fatalf("%+v %v", got, err)
	}
	if strings.Contains(text, "token") || strings.Contains(text, "endpoint") {
		t.Fatal("QR contains VPN settings")
	}
}
func TestInvalidCard(t *testing.T) {
	for _, card := range []Card{{V: 1}, {V: 3, PairURL: "https://example.com/v1/pair", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}, {V: 3, PairURL: "http://example.com/v1/pair", ServerPublicKey: "invalid"}} {
		if _, err := Marshal(card); err == nil {
			t.Fatal("expected error")
		}
	}
}
func TestEndpointAndKeyValidation(t *testing.T) {
	if ValidKey("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") {
		t.Fatal("zero key accepted")
	}
	for _, value := range []string{"host:0", "host:65536", "host:abc", "host"} {
		if _, _, err := SplitEndpoint(value); err == nil {
			t.Fatal(value)
		}
	}
	if _, _, err := SplitEndpoint("[2001:db8::1]:51820"); err != nil {
		t.Fatal(err)
	}
}

func TestUnjoinCardContainsOnlyPublicDiscoveryData(t *testing.T) {
	card := UnjoinCard{V: 2, Action: "unjoin", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=", UnjoinURL: "http://192.168.1.10:8756/v1/pair"}
	text, err := MarshalUnjoin(card)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseUnjoin(text)
	if err != nil || got != card {
		t.Fatalf("%+v %v", got, err)
	}
	if strings.Contains(text, "token") || strings.Contains(text, "private") || strings.Contains(text, "pair_url") {
		t.Fatalf("unexpected invitation information: %s", text)
	}
	if _, err := Parse(text); err == nil {
		t.Fatal("unjoin QR accepted as pairing invitation")
	}
	for _, change := range []func(*UnjoinCard){
		func(c *UnjoinCard) { c.Action = "pair" },
		func(c *UnjoinCard) { c.V = 1 },
		func(c *UnjoinCard) { c.ServerPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" },
		func(c *UnjoinCard) { c.UnjoinURL = "http://192.168.1.10:8756/wrong" },
	} {
		invalid := card
		change(&invalid)
		if _, err := MarshalUnjoin(invalid); err == nil {
			t.Fatal("invalid unjoin QR accepted")
		}
	}
}
