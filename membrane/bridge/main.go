// Slime OS — local kiosk bridge
//
// A thin, dumb relay between the lock screen's WebSocket connection
// (membrane/lockscreen/index.html, running inside cog/WPE WebKit) and a
// persistent bash coordinator process (membrane/session/coordinator.sh).
// It has no product logic of its own: every line the browser sends is
// forwarded verbatim to the coordinator's stdin, and every line the
// coordinator writes to its stdout is forwarded verbatim to the browser
// as a WebSocket text frame. See coordinator.sh's header comment for the
// JSON-line protocol both sides speak.
//
// The WebSocket server (RFC 6455) is hand-rolled against only the Go
// standard library rather than pulling in a third-party module: this
// binary sits in the same path as saved Brain credentials, so keeping its
// dependency graph at zero external packages keeps it fully auditable
// from this one file.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const wsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

func main() {
	listen := flag.String("listen", "127.0.0.1:7770", "address to listen on (must be loopback)")
	coordinatorPath := flag.String("coordinator", "/opt/slimeos/coordinator.sh", "path to the coordinator script")
	logPath := flag.String("log", "/var/log/slimeos/coordinator.log", "coordinator stderr log path")
	flag.Parse()

	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		log.Fatalf("invalid --listen address %q: %v", *listen, err)
	}
	if host != "localhost" {
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			log.Fatalf("refusing to bind non-loopback address %q", *listen)
		}
	}

	b := &bridge{coordinatorPath: *coordinatorPath, logPath: *logPath}
	go b.runCoordinatorLoop()
	go startHotkeyWatcher(b)

	log.Printf("slimeos-bridge listening on %s (coordinator=%s)", *listen, *coordinatorPath)
	if err := http.ListenAndServe(*listen, http.HandlerFunc(b.handleWS)); err != nil {
		log.Fatal(err)
	}
}

// bridge owns the single persistent coordinator subprocess and the single
// "current" browser WebSocket connection (latest connection wins — a page
// reload simply supersedes the previous socket rather than being rejected).
type bridge struct {
	coordinatorPath string
	logPath         string

	mu            sync.Mutex
	currentClient *safeConn

	stdinMu sync.Mutex
	stdin   io.WriteCloser
}

// safeConn serializes writes to one net.Conn: the coordinator's stdout
// scanner goroutine and this connection's own ping/pong handling both need
// to write frames to the same socket, and interleaved writes would corrupt
// the WebSocket frame stream.
type safeConn struct {
	net.Conn
	mu sync.Mutex
}

func (c *safeConn) send(opcode byte, payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, err := c.Conn.Write(encodeFrame(opcode, payload))
	return err
}

func (b *bridge) writeToCoordinator(line string) {
	b.stdinMu.Lock()
	w := b.stdin
	b.stdinMu.Unlock()
	if w == nil {
		return
	}
	_, _ = io.WriteString(w, line+"\n")
}

// ── WebSocket handshake + per-connection read loop ──────────────────────────

func (b *bridge) handleWS(w http.ResponseWriter, r *http.Request) {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		http.Error(w, "expected websocket upgrade", http.StatusUpgradeRequired)
		return
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		http.Error(w, "missing Sec-WebSocket-Key", http.StatusBadRequest)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack not supported", http.StatusInternalServerError)
		return
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return
	}

	h := sha1.New()
	io.WriteString(h, key+wsMagic)
	accept := base64.StdEncoding.EncodeToString(h.Sum(nil))

	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	if _, err := rw.WriteString(resp); err != nil {
		conn.Close()
		return
	}
	if err := rw.Flush(); err != nil {
		conn.Close()
		return
	}

	b.attachClient(&safeConn{Conn: conn}, rw.Reader)
}

// attachClient makes conn the bridge's one active client ("latest wins" —
// any previously connected client is closed), notifies the coordinator so
// it can resync fresh state, then blocks reading frames until the
// connection closes.
func (b *bridge) attachClient(conn *safeConn, r *bufio.Reader) {
	defer conn.Close()

	b.mu.Lock()
	if b.currentClient != nil {
		b.currentClient.Close()
	}
	b.currentClient = conn
	b.mu.Unlock()

	b.writeToCoordinator(`{"type":"_clientConnected"}`)

	defer func() {
		b.mu.Lock()
		if b.currentClient == conn {
			b.currentClient = nil
		}
		b.mu.Unlock()
		b.writeToCoordinator(`{"type":"_clientDisconnected"}`)
	}()

	for {
		opcode, payload, err := readFrame(r)
		if err != nil {
			return
		}
		switch opcode {
		case opClose:
			return
		case opPing:
			_ = conn.send(opPong, payload)
		case opText:
			line := bytes.TrimRight(payload, "\r\n")
			if len(line) > 0 {
				b.writeToCoordinator(string(line))
			}
		}
	}
}

// ── Coordinator subprocess supervision ───────────────────────────────────────

func (b *bridge) runCoordinatorLoop() {
	for {
		b.runCoordinatorOnce()
		log.Printf("coordinator exited — restarting in 2s")
		time.Sleep(2 * time.Second)
	}
}

func (b *bridge) runCoordinatorOnce() {
	logFile, err := os.OpenFile(b.logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		log.Printf("cannot open coordinator log %s: %v (using stderr)", b.logPath, err)
	} else {
		defer logFile.Close()
	}

	cmd := exec.Command(b.coordinatorPath)
	if logFile != nil {
		cmd.Stderr = logFile
	} else {
		cmd.Stderr = os.Stderr
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		log.Printf("stdin pipe error: %v", err)
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		log.Printf("stdout pipe error: %v", err)
		return
	}
	if err := cmd.Start(); err != nil {
		log.Printf("failed to start coordinator: %v", err)
		return
	}
	log.Printf("coordinator started (pid %d)", cmd.Process.Pid)

	b.stdinMu.Lock()
	b.stdin = stdin
	b.stdinMu.Unlock()

	// A respawn (crash recovery) must resync whatever client is already
	// attached — it lost all coordinator-side state when the old process died.
	b.mu.Lock()
	hasClient := b.currentClient != nil
	b.mu.Unlock()
	if hasClient {
		b.writeToCoordinator(`{"type":"_clientConnected"}`)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		b.mu.Lock()
		client := b.currentClient
		b.mu.Unlock()
		if client == nil {
			continue // no browser attached right now — drop; next connect resyncs
		}
		if err := client.send(opText, []byte(line)); err != nil {
			b.mu.Lock()
			if b.currentClient == client {
				b.currentClient = nil
			}
			b.mu.Unlock()
		}
	}

	_ = cmd.Wait()

	b.stdinMu.Lock()
	b.stdin = nil
	b.stdinMu.Unlock()
}

// ── Global force-disconnect hotkey (Ctrl+Alt+End, held 3s) ──────────────────
//
// Once xfreerdp3 owns the Wayland surface there is no window chrome, no
// VT-switching (cage runs without -s), and the lock screen page -- which is
// what every other event in this protocol goes through -- has no input
// focus to receive anything on. This reads raw evdev events directly,
// below whatever currently has focus, so a stuck RDP session (or any other
// wedged screen) can always be escaped back to the picker. See
// coordinator.sh's header comment for the "forceBack" protocol entry this
// feeds.
//
// Was Ctrl+Alt+Backspace until 2026-08-14: this reader doesn't grab the
// device (see watchKeyboardDevice below), so the raw chord also reaches
// whatever xfreerdp3 has focused on the Brain side. Ctrl+Alt+Backspace is
// X11's classic "zap the X server" sequence -- if a Linux Brain's X
// server has DontZap off, holding it kills and restarts the Brain's
// whole desktop session, and it also ate any Ctrl+Alt+* binding a user
// actually wanted inside the remote session. Ctrl+Alt+End has no such
// reserved meaning on Windows or X11 desktops.
//
// Pure stdlib, matching this binary's zero-dependency rule (see the header
// comment above): finds keyboard-class device nodes by parsing
// /proc/bus/input/devices (plain text, no ioctls), then decodes raw
// input_event records by hand rather than via a cgo/unsafe struct cast.

const (
	evKey        = 1 // struct input_event .type for key press/release
	keyLeftCtrl  = 29
	keyRightCtrl = 97
	keyLeftAlt   = 56
	keyRightAlt  = 100
	keyEnd       = 107

	// struct input_event on 64-bit platforms: timeval (2x8-byte long) +
	// u16 type + u16 code + s32 value = 24 bytes. Read as raw offsets
	// rather than an unsafe-cast struct -- simpler and layout-proof.
	inputEventSize = 24
	typeOffset     = 16
	codeOffset     = 18
	valueOffset    = 20
)

// hotkeyState tracks chord state across every open keyboard device --
// deliberately global rather than per-device, so e.g. a Bluetooth
// keyboard's Ctrl plus a USB keyboard's Alt still counts. Cheap edge case
// to get right.
type hotkeyState struct {
	mu             sync.Mutex
	ctrl, alt, end bool
	timer          *time.Timer
}

func startHotkeyWatcher(b *bridge) {
	opened := map[string]bool{}
	hs := &hotkeyState{}
	for {
		devices, err := findKeyboardDevices()
		if err != nil {
			log.Printf("hotkey: device scan failed: %v", err)
		}
		for _, path := range devices {
			if opened[path] {
				continue
			}
			opened[path] = true
			go watchKeyboardDevice(path, hs, b)
		}
		time.Sleep(10 * time.Second) // re-scan for hotplugged keyboards
	}
}

// findKeyboardDevices parses /proc/bus/input/devices for blocks whose
// Handlers= line includes the "kbd" token -- Linux's own signal that a
// device is keyboard-class (as opposed to a mouse, touchpad, etc), rather
// than guessing from the device name.
func findKeyboardDevices() ([]string, error) {
	f, err := os.Open("/proc/bus/input/devices")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var found []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "H: Handlers=") {
			continue
		}
		isKbd, event := false, ""
		for _, field := range strings.Fields(strings.TrimPrefix(line, "H: Handlers=")) {
			if field == "kbd" {
				isKbd = true
			}
			if strings.HasPrefix(field, "event") {
				event = field
			}
		}
		if isKbd && event != "" {
			found = append(found, "/dev/input/"+event)
		}
	}
	return found, scanner.Err()
}

// watchKeyboardDevice opens one evdev node read-only (no EVIOCGRAB -- evdev
// nodes support multiple concurrent readers without it, which is exactly
// why this doesn't interfere with cage/libinput's own consumption of the
// same device) and feeds every key press/release into the shared chord
// tracker until the device goes away (unplugged).
func watchKeyboardDevice(path string, hs *hotkeyState, b *bridge) {
	f, err := os.Open(path)
	if err != nil {
		log.Printf("hotkey: cannot open %s: %v", path, err)
		return
	}
	defer f.Close()
	log.Printf("hotkey: watching %s for the force-disconnect chord", path)

	buf := make([]byte, inputEventSize)
	for {
		if _, err := io.ReadFull(f, buf); err != nil {
			log.Printf("hotkey: %s closed: %v", path, err)
			return
		}
		if binary.NativeEndian.Uint16(buf[typeOffset:]) != evKey {
			continue
		}
		code := binary.NativeEndian.Uint16(buf[codeOffset:])
		value := int32(binary.NativeEndian.Uint32(buf[valueOffset:]))
		hs.update(code, value != 0, b)
	}
}

// update folds one key event into the shared chord state. On the
// false->true transition it arms a one-shot 3s timer (so a stray tap can
// never fire it, and holding past 3s can't re-fire it either); any release
// before it fires cancels the timer.
func (hs *hotkeyState) update(code uint16, down bool, b *bridge) {
	hs.mu.Lock()
	defer hs.mu.Unlock()

	switch code {
	case keyLeftCtrl, keyRightCtrl:
		hs.ctrl = down
	case keyLeftAlt, keyRightAlt:
		hs.alt = down
	case keyEnd:
		hs.end = down
	default:
		return
	}

	chord := hs.ctrl && hs.alt && hs.end
	switch {
	case chord && hs.timer == nil:
		hs.timer = time.AfterFunc(3*time.Second, func() {
			log.Printf("hotkey: Ctrl+Alt+End held 3s -- forcing back to the picker")
			b.writeToCoordinator(`{"type":"forceBack"}`)
		})
	case !chord && hs.timer != nil:
		hs.timer.Stop()
		hs.timer = nil
	}
}

// ── Minimal RFC 6455 framing (text frames only; enough for JSON-line IPC) ──

func readFrame(r *bufio.Reader) (opcode byte, payload []byte, err error) {
	var header [2]byte
	if _, err = io.ReadFull(r, header[:]); err != nil {
		return
	}
	fin := header[0]&0x80 != 0
	opcode = header[0] & 0x0f
	masked := header[1]&0x80 != 0
	length := int64(header[1] & 0x7f)

	switch length {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return
		}
		length = int64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return
		}
		length = int64(binary.BigEndian.Uint64(ext[:]))
	}

	var maskKey [4]byte
	if masked {
		if _, err = io.ReadFull(r, maskKey[:]); err != nil {
			return
		}
	}

	data := make([]byte, length)
	if _, err = io.ReadFull(r, data); err != nil {
		return
	}
	if masked {
		for i := range data {
			data[i] ^= maskKey[i%4]
		}
	}

	if !fin {
		// Continuation frames carry opcode 0x0; the overall message's
		// opcode is whatever the first frame declared, so keep `opcode`
		// from this call and only fold in the continuation's payload.
		_, rest, ferr := readFrame(r)
		if ferr != nil {
			return opcode, nil, ferr
		}
		data = append(data, rest...)
	}

	return opcode, data, nil
}

func encodeFrame(opcode byte, payload []byte) []byte {
	var buf bytes.Buffer
	buf.WriteByte(0x80 | opcode) // FIN set, no fragmentation on the server->client side
	l := len(payload)
	switch {
	case l <= 125:
		buf.WriteByte(byte(l))
	case l <= 65535:
		buf.WriteByte(126)
		var ext [2]byte
		binary.BigEndian.PutUint16(ext[:], uint16(l))
		buf.Write(ext[:])
	default:
		buf.WriteByte(127)
		var ext [8]byte
		binary.BigEndian.PutUint64(ext[:], uint64(l))
		buf.Write(ext[:])
	}
	buf.Write(payload)
	return buf.Bytes()
}
