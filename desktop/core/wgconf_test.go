package main

import (
	"strings"
	"testing"
)

const testKey = "a2tra2tra2tra2tra2tra2tra2tra2tra2tra2tra2s="

func TestParseProvisionedConfig(t *testing.T) {
	// The shape provision-peer.sh writes, empty DNS included.
	text := `[Interface]
PrivateKey = ` + testKey + `
Address = 10.10.0.40
DNS =

[Peer]
PublicKey = ` + testKey + `
PresharedKey = ` + testKey + `
Endpoint = 192.0.2.1:51820
# comment
AllowedIPs = 10.10.0.0/24, 10.11.0.0/24
PersistentKeepalive = 25
`
	cfg, err := parseWGConfig(text)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.MTU != 1280 || len(cfg.Peers) != 1 || len(cfg.Peers[0].AllowedIPs) != 2 {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	u, err := cfg.uapi()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"endpoint=192.0.2.1:51820", "allowed_ip=10.11.0.0/24", "persistent_keepalive_interval=25"} {
		if !strings.Contains(u, want) {
			t.Errorf("uapi lacks %q:\n%s", want, u)
		}
	}
}

func TestParseRejects(t *testing.T) {
	base := "[Interface]\nPrivateKey = " + testKey + "\nAddress = 10.10.0.40\n[Peer]\nPublicKey = " + testKey + "\n"
	for name, text := range map[string]string{
		"default route": base + "AllowedIPs = 10.10.0.0/24, 0.0.0.0/0\n",
		"ipv6 default":  base + "AllowedIPs = ::/0\n",
		"PostUp":        base + "AllowedIPs = 10.10.0.0/24\n[Interface]\nPostUp = rm -rf /\n",
		"unknown key":   base + "AllowedIPs = 10.10.0.0/24\nTable = off\n",
		"bad key":       strings.Replace(base, testKey, "abc", 1) + "AllowedIPs = 10.10.0.0/24\n",
		"no peer":       "[Interface]\nPrivateKey = " + testKey + "\nAddress = 10.10.0.40\n",
	} {
		if _, err := parseWGConfig(text); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
