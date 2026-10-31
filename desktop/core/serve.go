package main

// serve: the desktop app's backend. The window (desktop/app) runs this as a
// sidecar and talks to it over stdin/stdout, one JSON object per line.
//
// In:  {"id":N,"cmd":"..."[,"code":".."][,"brainId":".."]}
// Out: {"id":N,"ok":true,"data":{..}} | {"id":N,"ok":false,"code":"..","error":".."}
//      {"event":"stage","text":".."}                         progress while connecting
//      {"event":"session","state":"open","name":".."} | {"event":"session","state":"closed"}
//
// Commands:
//   state          version, platform, pairing and Slime ID status
//   slimeIdStart   a device code to approve at slimeos.com/device
//   slimeIdWait    blocks until that code is approved (or expires / is cancelled)
//   slimeIdLogout
//   brains         the account's Brains (needs Slime ID)
//   pair {code}    a pairing code from the dashboard; replaces this PC's tunnel
//   forgetPairing
//   connect {brainId}  tunnel, sign-in, wake, then the RDP client; replies when it closes
//   cancel         ends the running slimeIdWait or connect (closes the RDP client)
//
// Error codes: not_paired, signed_out, expired, cancelled, hub, not_allowed,
// unreachable, wake_failed, busy, pair, unknown_brain, client.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"
)

var version = "dev" // -ldflags "-X main.version=..."

type appError struct {
	Code string
	Msg  string
}

func (e *appError) Error() string { return e.Msg }

func fail(code, format string, a ...any) error { return &appError{code, fmt.Sprintf(format, a...)} }

type request struct {
	ID      int    `json:"id"`
	Cmd     string `json:"cmd"`
	Code    string `json:"code"`
	BrainID string `json:"brainId"`
}

type server struct {
	outMu sync.Mutex
	out   *json.Encoder

	mu      sync.Mutex
	session *slimeSession
	code    *deviceCode
	brains  []remoteBrain
	tun     *tunnel
	cancel  context.CancelFunc // the running slimeIdWait or connect
	jobSeq  int
}

func cmdServe(args []string) error {
	openLogFile()
	log.Printf("Slime OS desktop core %s (%s/%s)", version, runtime.GOOS, runtime.GOARCH)
	s := &server{out: json.NewEncoder(os.Stdout), session: loadSession()}
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 64<<10), 64<<10)
	for sc.Scan() {
		var req request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			log.Printf("bad request: %v", err)
			continue
		}
		go s.handle(req)
	}
	// The window closed: end whatever runs (the RDP client goes with it).
	s.cancelJob()
	return nil
}

// openLogFile tees the log into SlimeOS/desktop.log, started fresh once it's large.
func openLogFile() {
	path, err := configPath()
	if err != nil {
		return
	}
	path = filepath.Join(filepath.Dir(path), "desktop.log")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if fi, err := os.Stat(path); err == nil && fi.Size() > 2<<20 {
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		return
	}
	log.SetFlags(log.Ldate | log.Ltime)
	log.SetOutput(io.MultiWriter(os.Stderr, f))
}

func (s *server) send(v any) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	s.out.Encode(v)
}

func (s *server) event(name string, fields map[string]any) {
	m := map[string]any{"event": name}
	for k, v := range fields {
		m[k] = v
	}
	s.send(m)
}

func (s *server) stage(text string) {
	log.Print(text)
	s.event("stage", map[string]any{"text": text})
}

func (s *server) handle(req request) {
	data, err := s.dispatch(req)
	if err != nil {
		var ae *appError
		if !errors.As(err, &ae) {
			ae = &appError{"error", err.Error()}
		}
		log.Printf("%s: %s (%s)", req.Cmd, ae.Msg, ae.Code)
		s.send(map[string]any{"id": req.ID, "ok": false, "code": ae.Code, "error": ae.Msg})
		return
	}
	if data == nil {
		data = map[string]any{}
	}
	s.send(map[string]any{"id": req.ID, "ok": true, "data": data})
}

func (s *server) dispatch(req request) (any, error) {
	switch req.Cmd {
	case "state":
		return s.state(), nil
	case "slimeIdStart":
		s.cancelJob()
		c, err := slimeIDStart()
		if err != nil {
			return nil, fail("hub", "Couldn't reach slimeos.com. Check this PC's internet connection.")
		}
		s.mu.Lock()
		s.code = c
		s.mu.Unlock()
		return c, nil
	case "slimeIdWait":
		ctx, done := s.startJob()
		defer done()
		return s.slimeIDWait(ctx)
	case "slimeIdLogout":
		s.mu.Lock()
		sess := s.session
		s.session, s.brains = nil, nil
		s.mu.Unlock()
		if sess != nil {
			slimeIDLogout(sess.Token)
		}
		return nil, saveSession(nil)
	case "brains":
		return s.listBrains()
	case "pair":
		return s.pair(req.Code)
	case "forgetPairing":
		s.cancelJob()
		s.closeTunnel()
		path, err := configPath()
		if err == nil {
			err = os.Remove(path)
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		return nil, nil
	case "connect":
		ctx, done := s.startJob()
		defer done()
		return nil, s.connect(ctx, req.BrainID)
	case "cancel":
		s.cancelJob()
		return nil, nil
	}
	return nil, fail("error", "unknown command %q", req.Cmd)
}

// startJob cancels the running job and starts a new one.
func (s *server) startJob() (context.Context, func()) {
	s.cancelJob()
	ctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	s.jobSeq++
	seq := s.jobSeq
	s.cancel = cancel
	s.mu.Unlock()
	return ctx, func() {
		cancel()
		s.mu.Lock()
		if s.jobSeq == seq {
			s.cancel = nil
		}
		s.mu.Unlock()
	}
}

func (s *server) cancelJob() {
	s.mu.Lock()
	cancel := s.cancel
	s.cancel = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *server) state() map[string]any {
	st := map[string]any{"version": version, "platform": runtime.GOOS, "paired": false, "tunnelIP": nil, "signedIn": nil}
	if cfg, err := loadConfig(); err == nil && len(cfg.Addresses) > 0 {
		st["paired"] = true
		st["tunnelIP"] = cfg.Addresses[0].String()
	}
	s.mu.Lock()
	if s.session != nil {
		st["signedIn"] = map[string]string{"email": s.session.Email, "name": s.session.Name}
	}
	s.mu.Unlock()
	return st
}

func (s *server) slimeIDWait(ctx context.Context) (any, error) {
	s.mu.Lock()
	c := s.code
	s.mu.Unlock()
	if c == nil {
		return nil, fail("expired", "Start the sign-in again.")
	}
	deadline := time.Now().Add(time.Duration(c.ExpiresIn) * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return nil, fail("cancelled", "Cancelled.")
		case <-time.After(time.Duration(c.Interval) * time.Second):
		}
		sess, err := slimeIDPoll(c.DeviceCode)
		if errors.Is(err, errExpired) {
			break
		}
		if sess != nil {
			if err := saveSession(sess); err != nil {
				log.Printf("saving the Slime ID session: %v", err)
			}
			s.mu.Lock()
			s.session, s.code = sess, nil
			s.mu.Unlock()
			log.Printf("signed in to Slime ID as %s", sess.Email)
			return map[string]string{"email": sess.Email, "name": sess.Name}, nil
		}
	}
	return nil, fail("expired", "The sign-in code expired. Start again for a new one.")
}

func (s *server) listBrains() (any, error) {
	s.mu.Lock()
	sess := s.session
	s.mu.Unlock()
	if sess == nil {
		return nil, fail("signed_out", "Sign in with Slime ID to see your Brains.")
	}
	list, err := slimeIDBrains(sess.Token)
	if err != nil {
		return nil, fail("hub", "Couldn't load your Brains: %v", err)
	}
	s.mu.Lock()
	s.brains = list
	s.mu.Unlock()
	return map[string]any{"brains": list}, nil
}

func (s *server) pair(code string) (any, error) {
	if code == "" {
		return nil, fail("pair", "Enter the pairing code from your dashboard.")
	}
	text, err := fetchPairing("enroll.slimeos.com", code)
	if err != nil {
		return nil, fail("pair", "%s", pairingMessage(err))
	}
	cfg, err := parseWGConfig(text)
	if err != nil {
		return nil, fail("pair", "The pairing came back unusable: %v", err)
	}
	path, err := configPath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	// The code is single-use, so keep the config before anything else can fail.
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		return nil, err
	}
	s.closeTunnel()
	log.Printf("paired as %s", cfg.Addresses[0])
	return map[string]any{"tunnelIP": cfg.Addresses[0].String()}, nil
}

// pairingMessage: enroll's error codes in words (pair.sh's pair_error_message).
func pairingMessage(err error) string {
	switch err.Error() {
	case "pairing: invalid_code", "pairing: not_found":
		return "That code isn't valid. Check it and try again."
	case "pairing: expired", "pairing: code_expired":
		return "That code expired. Make a new one on your dashboard."
	case "pairing: used", "pairing: code_used", "pairing: already_used":
		return "That code was already used. Make a new one on your dashboard."
	}
	return "Couldn't pair: " + err.Error()
}

func loadConfig() (*wgConfig, error) {
	path, err := configPath()
	if err != nil {
		return nil, err
	}
	text, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseWGConfig(string(text))
}

func (s *server) closeTunnel() {
	s.mu.Lock()
	t := s.tun
	s.tun = nil
	s.mu.Unlock()
	if t != nil {
		t.Close()
	}
}

// ensureTunnel brings the tunnel up once and keeps it for the app's lifetime.
func (s *server) ensureTunnel() (*tunnel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tun != nil {
		return s.tun, nil
	}
	cfg, err := loadConfig()
	if errors.Is(err, os.ErrNotExist) {
		return nil, fail("not_paired", "Pair this PC first.")
	}
	if err != nil {
		return nil, fail("not_paired", "The saved pairing couldn't be read. Pair this PC again.")
	}
	t, err := startTunnel(cfg, false)
	if err != nil {
		return nil, err
	}
	if err := t.waitForHandshake(15 * time.Second); err != nil {
		t.Close()
		return nil, fail("hub", "Couldn't reach the Slime OS network. Check this PC's internet connection.")
	}
	log.Printf("tunnel up as %s", cfg.Addresses[0])
	s.tun = t
	return t, nil
}

func (s *server) connect(ctx context.Context, brainID string) error {
	s.mu.Lock()
	sess := s.session
	var b *remoteBrain
	for i := range s.brains {
		if s.brains[i].ID == brainID {
			b = &s.brains[i]
		}
	}
	s.mu.Unlock()
	if b == nil {
		return fail("unknown_brain", "That Brain isn't on your account any more.")
	}
	s.stage("Opening the secure tunnel…")
	t, err := s.ensureTunnel()
	if err != nil {
		return err
	}
	// A paid Brain's Windows sign-in comes from Slime ID, fresh every time and
	// never stored here. Anything else: the RDP client asks.
	var cred credential
	if b.Kind == "paid" && sess != nil {
		s.stage("Getting your sign-in from Slime ID…")
		if c, err := slimeIDCredential(sess.Token, b.ID); err != nil {
			log.Printf("%v; the RDP client will ask", err)
		} else {
			cred = *c
		}
	}
	s.stage("Waking up your Brain…")
	start := time.Now()
	err = t.wakeAndWait(ctx, b.Host, b.Port, s.stage)
	switch {
	case ctx.Err() != nil:
		return fail("cancelled", "Cancelled.")
	case errors.Is(err, errNotAllowed):
		return fail("not_allowed", "“%s” is asleep, and this PC isn't allowed to wake it yet. Wake it from another device, then try again.", b.Name)
	case errors.Is(err, errUnreachable):
		return fail("unreachable", "“%s” doesn't answer over this PC's pairing. It may be switched off, or it needs a pairing code of its own.", b.Name)
	case err != nil:
		return fail("wake_failed", "“%s” didn't wake up: %v", b.Name, err)
	}
	log.Printf("Brain ready after %s", time.Since(start).Round(time.Second))

	s.stage("Connecting…")
	ln, err := net.Listen("tcp", defaultListen)
	if err != nil {
		return fail("busy", "Another Brain session is already open on this PC.")
	}
	fctx, stop := context.WithCancel(ctx)
	defer stop()
	target := net.JoinHostPort(b.Host, strconv.Itoa(b.Port))
	go t.forwardOn(fctx, ln, target)
	s.event("session", map[string]any{"state": "open", "name": b.Name})
	err = runClient(fctx, rdpLaunch{Addr: ln.Addr().String(), Name: b.Name, Username: cred.Username, Password: cred.Password})
	stop()
	s.event("session", map[string]any{"state": "closed"})
	log.Printf("session with %s ended", b.Name)
	if err != nil {
		return fail("client", "%v", err)
	}
	return nil
}

// rdpLaunch is what the platform's remote-desktop client needs (launch_*.go).
type rdpLaunch struct {
	Addr               string // the loopback forward
	Name               string // the Brain's name, for the window title
	Username, Password string // empty: the client asks
}
