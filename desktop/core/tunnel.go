package main

// The tunnel lives entirely inside this process: wireguard-go (the same
// engine as the iOS and Android apps) on top of gVisor's userspace network
// stack. No driver, no admin rights, no VPN adapter, and nothing else on the
// PC is routed through it. The remote-desktop client reaches a Brain through
// a loopback port that forward() pipes into the tunnel.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type tunnel struct {
	dev  *device.Device
	tnet *netstack.Net
}

func startTunnel(cfg *wgConfig, verbose bool) (*tunnel, error) {
	uapi, err := cfg.uapi()
	if err != nil {
		return nil, err
	}
	tdev, tnet, err := netstack.CreateNetTUN(cfg.Addresses, cfg.DNS, cfg.MTU)
	if err != nil {
		return nil, err
	}
	level := device.LogLevelError
	if verbose {
		level = device.LogLevelVerbose
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(level, "wireguard: "))
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	return &tunnel{dev: dev, tnet: tnet}, nil
}

func (t *tunnel) Close() { t.dev.Close() }

// lastHandshake reports the newest handshake with any peer (zero if none yet).
func (t *tunnel) lastHandshake() time.Time {
	s, err := t.dev.IpcGet()
	if err != nil {
		return time.Time{}
	}
	var newest time.Time
	var sec int64
	for _, line := range splitLines(s) {
		if n, ok := cutInt(line, "last_handshake_time_sec="); ok {
			sec = n
		} else if n, ok := cutInt(line, "last_handshake_time_nsec="); ok && sec > 0 {
			if ts := time.Unix(sec, n); ts.After(newest) {
				newest = ts
			}
			sec = 0
		}
	}
	return newest
}

func splitLines(s string) []string { return strings.Split(strings.TrimSpace(s), "\n") }

func cutInt(line, prefix string) (int64, bool) {
	v, ok := strings.CutPrefix(line, prefix)
	if !ok {
		return 0, false
	}
	n, err := strconv.ParseInt(v, 10, 64)
	return n, err == nil
}

func (t *tunnel) dial(ctx context.Context, addr string) (net.Conn, error) {
	return t.tnet.DialContext(ctx, "tcp", addr)
}

func (t *tunnel) httpClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DialContext: t.tnet.DialContext},
	}
}

// forward accepts on listen (a loopback address) and pipes each connection
// to target through the tunnel, until ctx ends.
func (t *tunnel) forward(ctx context.Context, listen, target string) error {
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	log.Printf("forwarding %s -> %s through the tunnel", ln.Addr(), target)
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go t.pipe(ctx, c, target)
	}
}

func (t *tunnel) pipe(ctx context.Context, local net.Conn, target string) {
	defer local.Close()
	dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	remote, err := t.dial(dctx, target)
	cancel()
	if err != nil {
		log.Printf("%s: %v", target, err)
		return
	}
	defer remote.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	cp := func(dst, src net.Conn) {
		defer wg.Done()
		if _, err := io.Copy(dst, src); err != nil && !errors.Is(err, net.ErrClosed) {
			log.Printf("%s: %v", target, err)
		}
		// Half-close so the other direction can finish, then unblock it.
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		} else {
			dst.Close()
		}
	}
	go cp(remote, local)
	go cp(local, remote)
	wg.Wait()
	log.Printf("%s: connection closed", target)
}

// waitForHandshake blocks until the hub answers or timeout passes.
func (t *tunnel) waitForHandshake(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !t.lastHandshake().IsZero() {
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("no answer from the relay after %s", timeout)
}
