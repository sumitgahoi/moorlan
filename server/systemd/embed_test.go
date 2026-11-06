package systemd

import (
	"strings"
	"testing"
)

func TestRenderHostWideUnit(t *testing.T) {
	text := Render()
	if !strings.Contains(text, "ExecStart=/usr/local/bin/moorlan --reconcile") {
		t.Fatalf("bad ExecStart:\n%s", text)
	}
	if strings.Contains(text, "--interface") || strings.Contains(text, "__IFACE__") {
		t.Fatalf("per-iface template still present:\n%s", text)
	}
	if !strings.Contains(text, "Restart=on-failure") || !strings.Contains(text, "StartLimitBurst=30") {
		t.Fatalf("missing systemd retry:\n%s", text)
	}
	if !strings.Contains(text, "network-online.target") {
		t.Fatalf("missing network-online dependency:\n%s", text)
	}
}

func TestUnitPath(t *testing.T) {
	if got := UnitPath(); got != "/etc/systemd/system/moorlan-reconcile.service" {
		t.Fatal(got)
	}
}
