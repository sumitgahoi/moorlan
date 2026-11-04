package payload

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

// Card is a pairing invitation, not the VPN configuration.
// Version 1 is the current pre-release protocol.
type Card struct {
	V               int    `json:"v"`
	PairURL         string `json:"pair_url"`
	ServerPublicKey string `json:"server_public_key"`
}

func Marshal(card Card) (string, error) {
	if err := Validate(card); err != nil {
		return "", err
	}
	raw, err := json.Marshal(card)
	return string(raw), err
}
func Parse(text string) (Card, error) {
	var card Card
	if err := json.Unmarshal([]byte(text), &card); err != nil {
		return Card{}, fmt.Errorf("qr payload: %w", err)
	}
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
	V               int    `json:"v"`
	Action          string `json:"action"`
	ServerPublicKey string `json:"server_public_key"`
	UnpairURL       string `json:"unpair_url"`
}

func MarshalUnpair(card UnpairCard) (string, error) {
	if err := card.Validate(); err != nil {
		return "", err
	}
	raw, err := json.Marshal(card)
	return string(raw), err
}
func ParseUnpair(text string) (UnpairCard, error) {
	var card UnpairCard
	if err := json.Unmarshal([]byte(text), &card); err != nil {
		return UnpairCard{}, err
	}
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
func validateControlURL(value string) error {
	control, err := url.Parse(value)
	if err != nil || control.Scheme != "http" || control.Hostname() == "" || control.Path != "/v1/pair" || control.User != nil || control.RawQuery != "" || control.Fragment != "" {
		return fmt.Errorf("invalid control URL %q", value)
	}
	return nil
}
