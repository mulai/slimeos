// slimeos-desktop-core — the backend of the Slime OS desktop app (#18).
//
// Pairing, the userspace tunnel, wake and a loopback port forward to a
// Brain. The desktop app runs it as a sidecar (serve); pair and connect
// drive the same pieces from the command line.
//
//	slimeos-desktop-core serve
//	slimeos-desktop-core pair [-host enroll.slimeos.com] <code>
//	slimeos-desktop-core connect [-listen ADDR] [-port 3389] <brain-ip>
//
// serve is the desktop app's backend (serve.go). connect brings the tunnel
// up, wakes the Brain, then forwards ADDR to the Brain's RDP port until
// Ctrl+C; point a remote-desktop client at ADDR.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "serve":
		err = cmdServe(os.Args[2:])
	case "pair":
		err = cmdPair(os.Args[2:])
	case "connect":
		err = cmdConnect(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		log.Fatal(err)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: slimeos-desktop-core serve | pair [-host H] <code> | connect [-listen ADDR] [-port N] <brain-ip>")
	os.Exit(2)
}

func configPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "SlimeOS", "tunnel.conf"), nil
}

var hostRE = regexp.MustCompile(`^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$`)

func cmdPair(args []string) error {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	host := fs.String("host", "enroll.slimeos.com", "enrollment host")
	fs.Parse(args)
	if fs.NArg() != 1 || !hostRE.MatchString(*host) {
		usage()
	}
	text, err := fetchPairing(*host, strings.TrimSpace(fs.Arg(0)))
	if err != nil {
		return err
	}
	if _, err := parseWGConfig(text); err != nil {
		return fmt.Errorf("rejected WireGuard config: %w", err)
	}
	path, err := configPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		return err
	}
	log.Printf("paired; tunnel config saved to %s", path)
	return nil
}

// fetchPairing is membrane/session/pair.sh's pair_fetch_config(): POST the
// one-time code to the enrollment host, get a wg-quick config back.
func fetchPairing(host, code string) (string, error) {
	body, _ := json.Marshal(map[string]string{"code": code})
	c := &http.Client{Timeout: 15 * time.Second}
	resp, err := c.Post("https://"+host+"/pair", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var r struct {
		OK     bool   `json:"ok"`
		Error  string `json:"error"`
		Config string `json:"config"`
	}
	if err := json.Unmarshal(text, &r); err != nil {
		return "", fmt.Errorf("pairing: bad response (HTTP %d)", resp.StatusCode)
	}
	if !r.OK {
		if r.Error == "" {
			r.Error = "unknown_error"
		}
		return "", errors.New("pairing: " + r.Error)
	}
	return r.Config, nil
}

func cmdConnect(args []string) error {
	fs := flag.NewFlagSet("connect", flag.ExitOnError)
	listen := fs.String("listen", defaultListen, "loopback address the RDP client connects to")
	port := fs.Int("port", 3389, "the Brain's RDP port")
	verbose := fs.Bool("v", false, "verbose WireGuard log")
	fs.Parse(args)
	if fs.NArg() != 1 {
		usage()
	}
	brain, err := netip.ParseAddr(fs.Arg(0))
	if err != nil {
		return fmt.Errorf("brain address: %w", err)
	}
	if ap, err := netip.ParseAddrPort(*listen); err != nil || !ap.Addr().IsLoopback() {
		return errors.New("-listen must be a loopback address:port")
	}

	path, err := configPath()
	if err != nil {
		return err
	}
	text, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("not paired yet (%w)", err)
	}
	cfg, err := parseWGConfig(string(text))
	if err != nil {
		return err
	}
	t, err := startTunnel(cfg, *verbose)
	if err != nil {
		return err
	}
	defer t.Close()
	if err := t.waitForHandshake(15 * time.Second); err != nil {
		return err
	}
	log.Printf("tunnel up as %s", cfg.Addresses[0])

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	start := time.Now()
	if err := t.wakeAndWait(ctx, brain.String(), *port, func(s string) { log.Print(s) }); err != nil {
		return err
	}
	log.Printf("Brain ready after %s", time.Since(start).Round(time.Second))
	return t.forward(ctx, *listen, brain.String()+":"+strconv.Itoa(*port))
}
