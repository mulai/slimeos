package main

// Parses the wg-quick config the enrollment host returns (see
// brain/wireguard/provision-peer.sh) into what wireguard-go's userspace
// device takes. Same rules as membrane/session/pair.sh's
// pair_sanitize_config(): only the keys a Slime OS tunnel needs, each value
// shape-checked, and never a default route. Nothing on the PC is routed
// through this tunnel anyway (it lives inside this process), but a pairing
// host still doesn't get to point it anywhere it likes.

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

type wgPeer struct {
	PublicKey    string // base64
	PresharedKey string // base64, optional
	Endpoint     string // host:port
	AllowedIPs   []netip.Prefix
	Keepalive    int
}

type wgConfig struct {
	PrivateKey string // base64
	Addresses  []netip.Addr
	DNS        []netip.Addr
	MTU        int
	Peers      []wgPeer
}

func parseWGConfig(text string) (*wgConfig, error) {
	cfg := &wgConfig{}
	var peer *wgPeer
	section := ""
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		switch strings.ToLower(line) {
		case "[interface]":
			if section != "" {
				return nil, errors.New("[Interface] must come first, once")
			}
			section = "interface"
			continue
		case "[peer]":
			if section == "" {
				return nil, errors.New("[Peer] before [Interface]")
			}
			cfg.Peers = append(cfg.Peers, wgPeer{})
			peer = &cfg.Peers[len(cfg.Peers)-1]
			section = "peer"
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, errors.New("unexpected line")
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		// provision-peer.sh writes `DNS = ` when the hub has no DNS line.
		if value == "" {
			continue
		}
		if err := setWGKey(cfg, peer, section, key, value); err != nil {
			return nil, fmt.Errorf("%s: %w", key, err)
		}
	}
	if cfg.PrivateKey == "" || len(cfg.Addresses) == 0 {
		return nil, errors.New("[Interface] lacks PrivateKey or Address")
	}
	if len(cfg.Peers) == 0 {
		return nil, errors.New("no [Peer]")
	}
	for _, p := range cfg.Peers {
		if p.PublicKey == "" || len(p.AllowedIPs) == 0 {
			return nil, errors.New("a [Peer] lacks PublicKey or AllowedIPs")
		}
	}
	if cfg.MTU == 0 {
		// The hub's peers run at 1280 (see the Membrane's MTU notes); wg-quick's
		// 1420 fragments on some mobile and hotel networks.
		cfg.MTU = 1280
	}
	return cfg, nil
}

func setWGKey(cfg *wgConfig, peer *wgPeer, section, key, value string) error {
	switch section + ":" + key {
	case "interface:privatekey":
		return checkKey(value, &cfg.PrivateKey)
	case "interface:address":
		for _, s := range splitList(value) {
			// "10.10.0.5/32" or "10.10.0.5": only the address matters here.
			s, _, _ = strings.Cut(s, "/")
			a, err := netip.ParseAddr(s)
			if err != nil {
				return err
			}
			cfg.Addresses = append(cfg.Addresses, a)
		}
	case "interface:dns":
		for _, s := range splitList(value) {
			a, err := netip.ParseAddr(s)
			if err != nil {
				return err
			}
			cfg.DNS = append(cfg.DNS, a)
		}
	case "interface:mtu":
		n, err := strconv.Atoi(value)
		if err != nil || n < 576 || n > 9000 {
			return errors.New("out of range")
		}
		cfg.MTU = n
	case "peer:publickey":
		return checkKey(value, &peer.PublicKey)
	case "peer:presharedkey":
		return checkKey(value, &peer.PresharedKey)
	case "peer:endpoint":
		if _, _, err := net.SplitHostPort(value); err != nil {
			return err
		}
		peer.Endpoint = value
	case "peer:allowedips":
		for _, s := range splitList(value) {
			p, err := netip.ParsePrefix(s)
			if err != nil {
				return err
			}
			// A Slime OS tunnel only routes to Brains.
			if p.Bits() == 0 {
				return errors.New("default route not allowed")
			}
			peer.AllowedIPs = append(peer.AllowedIPs, p)
		}
	case "peer:persistentkeepalive":
		if value == "off" {
			return nil
		}
		n, err := strconv.Atoi(value)
		if err != nil || n < 0 || n > 65535 {
			return errors.New("out of range")
		}
		peer.Keepalive = n
	default:
		return errors.New("not allowed")
	}
	return nil
}

func checkKey(value string, dst *string) error {
	b, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(b) != 32 {
		return errors.New("not a WireGuard key")
	}
	*dst = value
	return nil
}

func splitList(value string) []string {
	var out []string
	for _, s := range strings.Split(value, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

// uapi renders the config in wireguard-go's IpcSet format. Endpoints must be
// IP:port there, so host names are resolved here, IPv4 first (the hub has no
// IPv6 address).
func (c *wgConfig) uapi() (string, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", hexKey(c.PrivateKey))
	for _, p := range c.Peers {
		fmt.Fprintf(&b, "public_key=%s\n", hexKey(p.PublicKey))
		if p.PresharedKey != "" {
			fmt.Fprintf(&b, "preshared_key=%s\n", hexKey(p.PresharedKey))
		}
		if p.Endpoint != "" {
			ep, err := resolveEndpoint(p.Endpoint)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(&b, "endpoint=%s\n", ep)
		}
		if p.Keepalive > 0 {
			fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", p.Keepalive)
		}
		for _, a := range p.AllowedIPs {
			fmt.Fprintf(&b, "allowed_ip=%s\n", a)
		}
	}
	return b.String(), nil
}

func hexKey(b64 string) string {
	b, _ := base64.StdEncoding.DecodeString(b64)
	return hex.EncodeToString(b)
}

func resolveEndpoint(hostport string) (string, error) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return "", err
	}
	if a, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(a, mustPort(port)).String(), nil
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", host, err)
	}
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil {
			return net.JoinHostPort(ip4.String(), port), nil
		}
	}
	return net.JoinHostPort(ips[0].String(), port), nil
}

func mustPort(s string) uint16 {
	n, _ := strconv.Atoi(s)
	return uint16(n)
}
