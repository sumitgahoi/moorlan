package payload

import (
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

// Card is a pairing invitation, not the VPN configuration.
// Version 1 is the current pre-release protocol.
type Card struct {
	V               int
	PairURL         string
	ServerPublicKey string
}

// Marshal encodes a Camera-openable invite: moorlan://v1/pair?url=…&spk=…
func Marshal(card Card) (string, error) {
	if err := Validate(card); err != nil {
		return "", err
	}
	return encodeInvite("pair", card.PairURL, card.ServerPublicKey)
}

func Parse(text string) (Card, error) {
	action, controlURL, spk, err := decodeInvite(text)
	if err != nil {
		return Card{}, err
	}
	if action != "pair" {
		return Card{}, fmt.Errorf("not a pair invite")
	}
	card := Card{V: 1, PairURL: controlURL, ServerPublicKey: spk}
	if err := Validate(card); err != nil {
		return Card{}, err
	}
	return card, nil
}

func Validate(card Card) error {
	if card.V != 1 {
		return fmt.Errorf("unsupported QR version %d", card.V)
	}
	if err := validateControlURL(card.PairURL); err != nil {
		return err
	}
	if !ValidKey(card.ServerPublicKey) {
		return fmt.Errorf("invalid server public key")
	}
	return nil
}

func ValidKey(s string) bool {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	return err == nil && len(raw) == 32 && string(raw) != string(make([]byte, 32))
}

func SplitEndpoint(endpoint string) (string, string, error) {
	host, port, err := net.SplitHostPort(endpoint)
	n, portErr := strconv.Atoi(port)
	if err != nil || host == "" || portErr != nil || n < 1 || n > 65535 {
		return "", "", fmt.Errorf("invalid endpoint %q", endpoint)
	}
	return host, port, nil
}

// UnpairCard identifies a known host and its current LAN control URL. It carries
// no credential: permission comes from the device's saved per-peer HMAC token.
type UnpairCard struct {
	V               int
	Action          string
	ServerPublicKey string
	UnpairURL       string
}

// MarshalUnpair encodes moorlan://v1/unpair?url=…&spk=…
func MarshalUnpair(card UnpairCard) (string, error) {
	if err := card.Validate(); err != nil {
		return "", err
	}
	return encodeInvite("unpair", card.UnpairURL, card.ServerPublicKey)
}

func ParseUnpair(text string) (UnpairCard, error) {
	action, controlURL, spk, err := decodeInvite(text)
	if err != nil {
		return UnpairCard{}, err
	}
	if action != "unpair" {
		return UnpairCard{}, fmt.Errorf("not an unpair invite")
	}
	card := UnpairCard{V: 1, Action: "unpair", ServerPublicKey: spk, UnpairURL: controlURL}
	if err := card.Validate(); err != nil {
		return UnpairCard{}, err
	}
	return card, nil
}

func (card UnpairCard) Validate() error {
	if card.V != 1 || card.Action != "unpair" {
		return fmt.Errorf("unsupported unpair QR version or action")
	}
	if !ValidKey(card.ServerPublicKey) {
		return fmt.Errorf("invalid server public key")
	}
	return validateControlURL(card.UnpairURL)
}

func encodeInvite(action, controlURL, serverPublicKey string) (string, error) {
	q := url.Values{}
	q.Set("url", controlURL)
	q.Set("spk", serverPublicKey)
	u := url.URL{
		Scheme:   "moorlan",
		Host:     "v1",
		Path:     "/" + action,
		RawQuery: q.Encode(),
	}
	return u.String(), nil
}

func decodeInvite(text string) (action, controlURL, spk string, err error) {
	u, err := url.Parse(strings.TrimSpace(text))
	if err != nil || u.Scheme != "moorlan" || u.Host != "v1" {
		return "", "", "", fmt.Errorf("qr payload: expected moorlan://v1/… invite")
	}
	switch strings.Trim(u.Path, "/") {
	case "pair":
		action = "pair"
	case "unpair":
		action = "unpair"
	default:
		return "", "", "", fmt.Errorf("unsupported invite path %q", u.Path)
	}
	controlURL = u.Query().Get("url")
	spk = u.Query().Get("spk")
	if controlURL == "" || spk == "" {
		return "", "", "", fmt.Errorf("invite missing url or spk")
	}
	return action, controlURL, spk, nil
}

func validateControlURL(value string) error {
	control, err := url.Parse(value)
	if err != nil || control.Scheme != "http" || control.Hostname() == "" || control.Path != "/v1/pair" || control.User != nil || control.RawQuery != "" || control.Fragment != "" {
		return fmt.Errorf("invalid control URL %q", value)
	}
	return nil
}
