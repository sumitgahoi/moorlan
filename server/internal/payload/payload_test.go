package payload

import (
	"net/url"
	"strings"
	"testing"
)

func TestCardRoundTrip(t *testing.T) {
	card := Card{V: 1, PairURL: "http://192.168.1.10:8756/v1/pair", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}
	text, err := Marshal(card)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(text, "moorlan://v1/pair?") {
		t.Fatalf("not a moorlan pair invite: %s", text)
	}
	got, err := Parse(text)
	if err != nil || got != card {
		t.Fatalf("%+v %v", got, err)
	}
	u, err := url.Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	if u.Query().Get("url") != card.PairURL || u.Query().Get("spk") != card.ServerPublicKey {
		t.Fatalf("query: %v", u.Query())
	}
}

func TestCardRejectsBadVersionsAndURLs(t *testing.T) {
	for _, card := range []Card{{V: 2}, {V: 1, PairURL: "https://example.com/v1/pair", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}, {V: 1, PairURL: "http://example.com/v1/pair", ServerPublicKey: "invalid"}} {
		if _, err := Marshal(card); err == nil {
			t.Fatalf("accepted %+v", card)
		}
	}
}

func TestCardRejectsJSONPayload(t *testing.T) {
	if _, err := Parse(`{"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}`); err == nil {
		t.Fatal("accepted legacy JSON QR")
	}
}

func TestValidateLabel(t *testing.T) {
	if err := ValidateLabel("iPhone 17"); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "  ", "a\nb", strings.Repeat("x", 65), string([]byte{0xff, 0xfe})} {
		if err := ValidateLabel(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

func TestUnpairCardContainsOnlyPublicDiscoveryData(t *testing.T) {
	card := UnpairCard{V: 1, Action: "unpair", ServerPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=", UnpairURL: "http://192.168.1.10:8756/v1/pair"}
	text, err := MarshalUnpair(card)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(text, "moorlan://v1/unpair?") {
		t.Fatalf("not a moorlan unpair invite: %s", text)
	}
	got, err := ParseUnpair(text)
	if err != nil || got != card {
		t.Fatalf("%+v %v", got, err)
	}
	if strings.Contains(strings.ToLower(text), "token") {
		t.Fatal("unpair QR leaked a credential field")
	}
	if _, err := Parse(text); err == nil {
		t.Fatal("unpair QR accepted as pairing invitation")
	}
	for _, change := range []func(*UnpairCard){
		func(c *UnpairCard) { c.Action = "pair" },
		func(c *UnpairCard) { c.V = 2 },
		func(c *UnpairCard) { c.ServerPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" },
		func(c *UnpairCard) { c.UnpairURL = "http://192.168.1.10:8756/wrong" },
	} {
		invalid := card
		change(&invalid)
		if _, err := MarshalUnpair(invalid); err == nil {
			t.Fatal("invalid unpair QR accepted")
		}
	}
}
