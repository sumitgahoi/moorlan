package systemd

import (
	"strings"
	"testing"
)

func TestRenderSubstitutesInterface(t *testing.T) {
	text, err := Render("wg2")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(text, ifacePlaceholder) {
		t.Fatalf("still has placeholder:\n%s", text)
	}
	if !strings.Contains(text, "ExecStart=/usr/local/bin/moorlan --reconcile --interface wg2") {
		t.Fatalf("bad ExecStart:\n%s", text)
	}
	if !strings.Contains(text, "Restart=on-failure") || !strings.Contains(text, "StartLimitBurst=30") {
		t.Fatalf("missing systemd retry:\n%s", text)
	}
	if _, err := Render(""); err == nil {
		t.Fatal("empty iface accepted")
	}
}

func TestUnitPath(t *testing.T) {
	if got := UnitPath("wg1"); got != "/etc/systemd/system/moorlan-reconcile-wg1.service" {
		t.Fatal(got)
	}
}
