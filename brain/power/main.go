// Slime OS — Brain power management (auto-deallocate / wake-on-connect)
//
// A cloud Brain that runs 24/7 bills 24/7 (a Standard_D4s_v3 is ~$183/mo,
// deallocated it's ~$0 compute). This service closes that gap without any
// agent on the Windows VM and without any Membrane-side configuration:
//
//   - POST /wake {"host":"10.10.0.3"} — called by every Membrane before
//     every connect attempt (membrane/freerdp/connect.sh wake_brain()).
//     Unmanaged hosts get {managed:false} instantly and the Membrane
//     proceeds exactly as before this service existed. For a managed,
//     powered-off VM it issues an ARM start and reports state so the
//     Membrane can show "Waking up your Brain…" and poll.
//   - A watchdog counts the forwarded Membrane→VM RDP flows in this
//     network namespace's conntrack table and deallocates the VM once
//     they've been gone for POWER_IDLE_MINUTES. It also deallocates a VM
//     found merely "stopped" (a guest-initiated shutdown from inside
//     Windows leaves the VM allocated — and billing).
//
// Security model: there is no authentication in this file because the
// network IS the authentication. docker-compose runs this container with
// network_mode: service:wireguard and the listener binds 10.10.0.1:7677
// explicitly — the WireGuard interface address inside that namespace — so
// only WireGuard peers can ever reach it, exactly like RDP itself. It is
// deliberately NOT behind Caddy: a publicly reachable unauthenticated
// start endpoint is cost-griefing surface. Note there is no stop/
// deallocate HTTP endpoint at all (the watchdog is the only thing that
// powers anything off), so the worst a hostile peer could do is keep the
// VM awake. The explicit bind matters: a wildcard :7677 would also listen
// on the WireGuard container's docker-bridge addresses.
//
// Fail-safe posture throughout: conntrack unreadable, PowerState absent,
// ARM errors, token failures — every failure path holds power state as-is.
// The failure mode of this service is "bills money", never "kills a live
// session".
//
// Azure is spoken as raw REST (OAuth2 client-credentials + three ARM
// calls) rather than via the Azure SDK: same zero-external-dependency
// rationale as brain/enroll/main.go and membrane/bridge/main.go — this
// file holds cloud credentials and is fully auditable on its own.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	armAPIVersion = "2024-07-01"
	conntrackPath = "/proc/net/nf_conntrack"
	// Kernel default for nf_conntrack_tcp_timeout_established (5 days),
	// used only if the sysctl itself can't be read.
	defaultEstablishedTimeout = 432000
	stateCacheTTL             = 10 * time.Second
)

func main() {
	listen := flag.String("listen", "10.10.0.1:7677", "address to listen on (the wg0 address in the shared netns — do not widen to a wildcard)")
	debugConntrack := flag.String("debug-conntrack", "", "parse a conntrack dump file, print per-flow verdicts, and exit")
	debugHost := flag.String("debug-host", "", "with --debug-conntrack: only evaluate flows to this destination IP")
	flag.Parse()

	rdpPort := envInt("POWER_RDP_PORT", 3389)
	staleGrace := envInt("POWER_STALE_GRACE_SECONDS", 3600)
	idleMinutes := envInt("POWER_IDLE_MINUTES", 20)

	if *debugConntrack != "" {
		debugDump(*debugConntrack, *debugHost, strconv.Itoa(rdpPort), staleGrace)
		return
	}

	vms, err := parseVMs(os.Getenv("POWER_VMS"))
	if err != nil {
		log.Fatalf("bad POWER_VMS: %v", err)
	}

	s := &server{
		tenant:       os.Getenv("AZURE_TENANT_ID"),
		clientID:     os.Getenv("AZURE_CLIENT_ID"),
		clientSecret: os.Getenv("AZURE_CLIENT_SECRET"),
		httpc:        &http.Client{Timeout: 15 * time.Second},
		hosts:        make(map[string]*hostState),
		rdpPort:      strconv.Itoa(rdpPort),
		staleGrace:   staleGrace,
		idleTarget:   idleMinutes,
	}
	for host, ref := range vms {
		s.hosts[host] = &hostState{ref: ref}
	}

	// An empty POWER_VMS is not an error: the service can ship in
	// docker-compose before the env is filled in, answering {managed:false}
	// for everything. Credentials are only required once a VM is managed.
	if len(s.hosts) > 0 {
		if s.tenant == "" || s.clientID == "" || s.clientSecret == "" {
			log.Fatal("POWER_VMS is set but AZURE_TENANT_ID/AZURE_CLIENT_ID/AZURE_CLIENT_SECRET are not")
		}
		// The established-timeout ceiling for the staleness guard (see
		// countActiveRDP). Read once: it's a boot-time sysctl.
		s.maxEstablished = readIntFile("/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established", defaultEstablishedTimeout)
		go s.watchdog()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/wake", s.handleWake)
	mux.HandleFunc("/status", s.handleStatus)

	// Bind-retry loop: this process starts as soon as the wireguard
	// container's namespace exists, which is seconds before its init has
	// actually created wg0 / assigned 10.10.0.1 — a plain Listen would
	// crash-loop the container through that window.
	var ln net.Listener
	for attempt := 0; ; attempt++ {
		ln, err = net.Listen("tcp", *listen)
		if err == nil {
			break
		}
		if attempt == 0 {
			log.Printf("waiting for %s to become bindable (%v)", *listen, err)
		}
		time.Sleep(time.Second)
	}
	log.Printf("slimeos-power listening on %s (%d managed VM(s), idle threshold %dm)", *listen, len(s.hosts), idleMinutes)
	log.Fatal(http.Serve(ln, mux))
}

// ── Config ───────────────────────────────────────────────────────────────────

type vmRef struct {
	sub, rg, name string
}

func vmBase(r vmRef) string {
	return fmt.Sprintf("https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s", r.sub, r.rg, r.name)
}

// POWER_VMS format: "10.10.0.3=<subscriptionId>/<resourceGroup>/<vmName>",
// comma-separated for multiple VMs.
func parseVMs(s string) (map[string]vmRef, error) {
	out := make(map[string]vmRef)
	if strings.TrimSpace(s) == "" {
		return out, nil
	}
	for _, entry := range strings.Split(s, ",") {
		entry = strings.TrimSpace(entry)
		host, ref, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("entry %q is not host=sub/rg/vm", entry)
		}
		parts := strings.Split(ref, "/")
		if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
			return nil, fmt.Errorf("entry %q: want <subscriptionId>/<resourceGroup>/<vmName>", entry)
		}
		out[strings.TrimSpace(host)] = vmRef{sub: parts[0], rg: parts[1], name: parts[2]}
	}
	return out, nil
}

func envInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		log.Fatalf("bad %s=%q: %v", name, v, err)
	}
	return n
}

func readIntFile(path string, def int) int {
	b, err := os.ReadFile(path)
	if err != nil {
		log.Printf("cannot read %s (%v) — using default %d", path, err, def)
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return def
	}
	return n
}

// ── Server state ─────────────────────────────────────────────────────────────

type hostState struct {
	ref vmRef

	// All fields below are guarded by server.mu.
	state         string    // last known PowerState (cache)
	stateAt       time.Time // when it was fetched
	startInFlight bool
	lastWake      time.Time
	idleTicks     int
	stoppedTicks  int
	lastLogged    string // last state we logged (log transitions, not ticks)
}

type server struct {
	tenant, clientID, clientSecret string
	httpc                          *http.Client
	hosts                          map[string]*hostState
	rdpPort                        string
	staleGrace                     int
	idleTarget                     int
	maxEstablished                 int

	mu     sync.Mutex
	tok    string
	tokExp time.Time
}

type powerResponse struct {
	Managed bool   `json:"managed"`
	State   string `json:"state,omitempty"`
	Error   string `json:"error,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v powerResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ── HTTP handlers ────────────────────────────────────────────────────────────
// No rate limiter, unlike enroll: enroll faces the open internet through
// Caddy; this listener is reachable only by WireGuard peers, and its
// callers poll at 1 req/5s. WireGuard membership is the admission control.

type wakeRequest struct {
	Host string `json:"host"`
}

// handleWake is idempotent and doubles as the Membrane's polling endpoint
// (it polls /wake, not /status, on purpose): if the first call lands while
// the VM is still deallocating — the classic "user reconnects right after
// the idle watchdog fired" race — only a subsequent /wake can issue the
// start once deallocation completes. A read-only status poll would wait
// out the full client-side cap and fail.
func (s *server) handleWake(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req wakeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, powerResponse{Error: "bad_request"})
		return
	}

	hs, ok := s.hosts[req.Host]
	if !ok {
		// Not an error: this is the normal answer for every LAN Brain, the
		// hub's own xrdp desktop, and any host the operator hasn't put in
		// POWER_VMS. The Membrane proceeds straight to its RDP attempt.
		writeJSON(w, http.StatusOK, powerResponse{Managed: false})
		return
	}

	state, err := s.vmState(hs)
	if err != nil {
		log.Printf("wake %s: instanceView failed: %v", req.Host, err)
		// "unknown" keeps the Membrane polling instead of failing the
		// connect outright — transient ARM blips shouldn't surface to the
		// lock screen.
		writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "unknown"})
		return
	}

	// Any wake intent bumps the grace timestamp, even if the VM is already
	// up: the watchdog holds off idle-deallocation for the idle window
	// after this, covering the gap where a user has asked to connect but
	// no RDP flow exists yet (Windows booting, password being typed).
	s.mu.Lock()
	hs.lastWake = time.Now()
	s.mu.Unlock()

	switch state {
	case "running":
		writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "running"})

	case "deallocated", "stopped":
		s.mu.Lock()
		if hs.startInFlight {
			s.mu.Unlock()
			writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "starting"})
			return
		}
		hs.startInFlight = true
		s.mu.Unlock()

		err := s.startVM(hs) // synchronous: ARM accepts with a 202 within a second or two

		s.mu.Lock()
		hs.startInFlight = false
		hs.idleTicks = 0
		hs.stateAt = time.Time{} // drop the cached power state; it just changed
		s.mu.Unlock()

		if err != nil {
			// Real start failures happen (allocation capacity, quota,
			// expired client secret). Surface "failed" so the Membrane
			// stops waiting and falls through to its normal error screen;
			// the detail lives in this log.
			log.Printf("wake %s: ARM start failed: %v", req.Host, err)
			writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "failed", Error: "start_failed"})
			return
		}
		log.Printf("wake %s: start issued (%s)", req.Host, hs.ref.name)
		writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "starting"})

	default:
		// starting / stopping / deallocating / unknown: report as-is; the
		// Membrane keeps polling and a later /wake acts when actionable.
		writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: state})
	}
}

// handleStatus is a read-only debug endpoint (curl from the hub or a
// peer); the Membrane deliberately does not use it — see handleWake.
func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("host")
	hs, ok := s.hosts[host]
	if !ok {
		writeJSON(w, http.StatusOK, powerResponse{Managed: false})
		return
	}
	state, err := s.vmState(hs)
	if err != nil {
		writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: "unknown", Error: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, powerResponse{Managed: true, State: state})
}

// ── Azure ARM (raw REST, stdlib only) ────────────────────────────────────────

func (s *server) token() (string, error) {
	s.mu.Lock()
	if s.tok != "" && time.Now().Before(s.tokExp) {
		t := s.tok
		s.mu.Unlock()
		return t, nil
	}
	s.mu.Unlock()

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", s.clientID)
	form.Set("client_secret", s.clientSecret)
	form.Set("scope", "https://management.azure.com/.default")

	resp, err := s.httpc.PostForm("https://login.microsoftonline.com/"+s.tenant+"/oauth2/v2.0/token", form)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tr); err != nil || tr.AccessToken == "" {
		return "", fmt.Errorf("token endpoint HTTP %d: %s", resp.StatusCode, snippet(body))
	}

	s.mu.Lock()
	s.tok = tr.AccessToken
	// Relative arithmetic (now + expires_in − 5m), never an absolute
	// expiry timestamp from the response: immune to wall-clock skew.
	s.tokExp = time.Now().Add(time.Duration(tr.ExpiresIn-300) * time.Second)
	s.mu.Unlock()
	return tr.AccessToken, nil
}

func (s *server) armRequest(method, armURL string) (int, []byte, error) {
	for attempt := 0; ; attempt++ {
		tok, err := s.token()
		if err != nil {
			return 0, nil, err
		}
		req, err := http.NewRequest(method, armURL, nil)
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := s.httpc.Do(req)
		if err != nil {
			return 0, nil, err
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()

		if resp.StatusCode == http.StatusUnauthorized && attempt == 0 {
			// Token revoked/expired early — drop the cache and retry once.
			s.mu.Lock()
			s.tok = ""
			s.mu.Unlock()
			continue
		}
		if resp.StatusCode == http.StatusTooManyRequests {
			// Our call volume (≤6 GETs/min during a wake + 1/min watchdog)
			// makes this unlikely; if it happens, callers lean on the 10s
			// state cache and the Membrane's next poll.
			log.Printf("ARM throttled (Retry-After: %s)", resp.Header.Get("Retry-After"))
			return resp.StatusCode, body, fmt.Errorf("ARM throttled")
		}
		return resp.StatusCode, body, nil
	}
}

// vmState returns the VM's PowerState suffix: running, starting, stopping,
// stopped, deallocating, deallocated — or "unknown" when the PowerState
// status is absent (which genuinely happens mid-transition and during
// platform maintenance). Callers must treat "unknown" as "take no action".
func (s *server) vmState(hs *hostState) (string, error) {
	s.mu.Lock()
	if hs.state != "" && time.Since(hs.stateAt) < stateCacheTTL {
		st := hs.state
		s.mu.Unlock()
		return st, nil
	}
	s.mu.Unlock()

	status, body, err := s.armRequest("GET", vmBase(hs.ref)+"/instanceView?api-version="+armAPIVersion)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("instanceView HTTP %d: %s", status, snippet(body))
	}

	var iv struct {
		Statuses []struct {
			Code string `json:"code"`
		} `json:"statuses"`
	}
	if err := json.Unmarshal(body, &iv); err != nil {
		return "", err
	}
	state := "unknown"
	for _, st := range iv.Statuses {
		if rest, ok := strings.CutPrefix(st.Code, "PowerState/"); ok {
			state = rest
			break
		}
	}

	s.mu.Lock()
	hs.state = state
	hs.stateAt = time.Now()
	s.mu.Unlock()
	return state, nil
}

func (s *server) startVM(hs *hostState) error {
	return s.powerOp(hs, "start")
}

func (s *server) deallocateVM(hs *hostState) error {
	return s.powerOp(hs, "deallocate")
}

func (s *server) powerOp(hs *hostState, op string) error {
	status, body, err := s.armRequest("POST", vmBase(hs.ref)+"/"+op+"?api-version="+armAPIVersion)
	if err != nil {
		return err
	}
	switch status {
	case http.StatusOK, http.StatusAccepted:
		return nil
	case http.StatusConflict:
		// A power operation is already in flight (e.g. start issued while
		// still deallocating). The next poll acts on the settled state.
		log.Printf("%s %s: 409 conflict (operation already in progress) — ignoring", op, hs.ref.name)
		return nil
	default:
		return fmt.Errorf("%s HTTP %d: %s", op, status, snippet(body))
	}
}

func snippet(b []byte) string {
	s := string(b)
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return strings.ReplaceAll(s, "\n", " ")
}

// ── Idle detection (conntrack) ───────────────────────────────────────────────

type flowVerdict struct {
	counted bool
	reason  string // why not counted (for --debug-conntrack)
	dst     string
	dport   string
	state   string
}

// parseConntrackLine evaluates one /proc/net/nf_conntrack line against a
// destination host:port. Format (fields):
//
//	ipv4  2 tcp  6 431999 ESTABLISHED src=A dst=B sport=X dport=3389 src=B dst=A … [ASSURED] …
//	[0]  [1] [2] [3]  [4]      [5]    ── original tuple ──────────── ── reply tuple ──
//
// Rules, each of which exists because the naive version miscounts:
//   - Only the ORIGINAL tuple's dst/dport (the first dst= / first dport=
//     on the line): a substring match would also hit the reply tuple of
//     an unrelated flow originating FROM the VM.
//   - Only l4 "tcp" in state ESTABLISHED, and never [UNREPLIED] lines
//     (half-open SYNs, dead-peer probes).
//   - Staleness guard: field 4 is the entry's REMAINING timeout, which the
//     kernel refreshes to the maximum (nf_conntrack_tcp_timeout_established,
//     default 5 days) on every packet. A Membrane that was hard-powered-off
//     mid-session leaves its ESTABLISHED entry decaying for those 5 days —
//     which would defeat idle detection entirely. Counting a flow only if
//     remaining > max − staleGrace means "a packet crossed this flow within
//     the last staleGrace seconds". A live RDP session (even parked at the
//     Windows lock screen) chatters far more often than the 1h default.
func parseConntrackLine(line, dstIP, dstPort string, maxTimeout, staleGrace int) flowVerdict {
	f := strings.Fields(line)
	if len(f) < 6 || f[2] != "tcp" {
		return flowVerdict{reason: "not tcp"}
	}
	v := flowVerdict{state: f[5]}
	if f[5] != "ESTABLISHED" {
		v.reason = "state " + f[5]
		return v
	}
	if strings.Contains(line, "[UNREPLIED]") {
		v.reason = "unreplied"
		return v
	}
	for _, tok := range f[6:] {
		if v.dst == "" {
			if rest, ok := strings.CutPrefix(tok, "dst="); ok {
				v.dst = rest
				continue
			}
		}
		if v.dport == "" {
			if rest, ok := strings.CutPrefix(tok, "dport="); ok {
				v.dport = rest
			}
		}
		if v.dst != "" && v.dport != "" {
			break
		}
	}
	if dstIP != "" && v.dst != dstIP {
		v.reason = "other dst " + v.dst
		return v
	}
	if v.dport != dstPort {
		v.reason = "other dport " + v.dport
		return v
	}
	remaining, err := strconv.Atoi(f[4])
	if err != nil {
		v.reason = "unparseable timeout"
		return v
	}
	if maxTimeout > staleGrace && remaining <= maxTimeout-staleGrace {
		v.reason = fmt.Sprintf("stale (no packet for ≥%ds)", maxTimeout-remaining)
		return v
	}
	v.counted = true
	return v
}

// countActiveRDP counts live RDP flows to host. Any error is returned as
// an error — never as a fake zero, which the watchdog would act on.
func (s *server) countActiveRDP(host string) (int, error) {
	f, err := os.Open(conntrackPath)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if parseConntrackLine(sc.Text(), host, s.rdpPort, s.maxEstablished, s.staleGrace).counted {
			n++
		}
	}
	if err := sc.Err(); err != nil {
		return 0, err
	}
	return n, nil
}

// ── Watchdog ─────────────────────────────────────────────────────────────────

func (s *server) watchdog() {
	ticker := time.NewTicker(time.Minute)
	wg0Missing := 0
	conntrackWarned := false
	idleWindow := time.Duration(s.idleTarget) * time.Minute

	for range ticker.C {
		// Self-heal: if the wireguard container restarts in place, this
		// process stays attached to the DEAD network sandbox — listener
		// and egress silently gone. Exiting lets restart:unless-stopped
		// bring the container back joined to the new sandbox.
		if _, err := os.Stat("/sys/class/net/wg0"); err != nil {
			wg0Missing++
			if wg0Missing >= 3 {
				log.Printf("wg0 has been missing for %d checks — namespace is stale, exiting for a clean rejoin", wg0Missing)
				os.Exit(1)
			}
			continue
		}
		wg0Missing = 0

		for host, hs := range s.hosts {
			state, err := s.vmState(hs)
			if err != nil {
				log.Printf("watchdog %s: instanceView failed: %v", host, err)
				continue
			}

			s.mu.Lock()
			if state != hs.lastLogged {
				log.Printf("%s (%s) is %s", host, hs.ref.name, state)
				hs.lastLogged = state
			}
			s.mu.Unlock()

			switch state {
			case "stopped":
				// Guest-initiated shutdown (user hit Start → Shut down
				// inside Windows). Azure keeps the VM allocated — and
				// billed. Two consecutive reads guard against a transient
				// reading mid-transition.
				s.mu.Lock()
				hs.stoppedTicks++
				fire := hs.stoppedTicks >= 2
				s.mu.Unlock()
				if fire {
					log.Printf("%s stopped (not deallocated) — deallocating to stop billing", host)
					if err := s.deallocateVM(hs); err != nil {
						log.Printf("deallocate %s failed: %v", host, err)
					}
					s.mu.Lock()
					hs.stoppedTicks = 0
					hs.stateAt = time.Time{}
					s.mu.Unlock()
				}

			case "running":
				s.mu.Lock()
				hs.stoppedTicks = 0
				s.mu.Unlock()

				flows, err := s.countActiveRDP(host)
				if err != nil {
					// Never deallocate blind. Warn once, not every minute.
					if !conntrackWarned {
						log.Printf("conntrack unreadable (%v) — idle auto-deallocate DISABLED until it recovers", err)
						conntrackWarned = true
					}
					continue
				}
				conntrackWarned = false

				s.mu.Lock()
				switch {
				case flows > 0:
					hs.idleTicks = 0
				case time.Since(hs.lastWake) < idleWindow:
					// Post-wake grace: a freshly started VM has zero flows
					// while Windows boots and the user types a password.
				default:
					hs.idleTicks++
				}
				fire := hs.idleTicks >= s.idleTarget
				s.mu.Unlock()

				if fire {
					// Final fresh read immediately before acting: shrinks
					// the decide-vs-connect race to about a second.
					again, err := s.countActiveRDP(host)
					if err != nil || again > 0 {
						continue
					}
					log.Printf("%s idle for %dm — deallocating %s", host, s.idleTarget, hs.ref.name)
					if err := s.deallocateVM(hs); err != nil {
						log.Printf("deallocate %s failed: %v", host, err)
					}
					s.mu.Lock()
					hs.idleTicks = 0
					hs.stateAt = time.Time{}
					s.mu.Unlock()
				}

			default:
				// starting/stopping/deallocating/deallocated/unknown:
				// nothing to decide.
				s.mu.Lock()
				hs.stoppedTicks = 0
				s.mu.Unlock()
			}
		}
	}
}

// ── --debug-conntrack ────────────────────────────────────────────────────────
// Parses a saved conntrack dump and prints one verdict per line — for
// developing the parser locally and for diagnosing "why didn't it
// deallocate" on the hub:
//
//	docker exec slimeos-power /usr/local/bin/slimeos-power \
//	    --debug-conntrack /proc/net/nf_conntrack --debug-host 10.10.0.3

func debugDump(path, host, port string, staleGrace int) {
	maxTimeout := readIntFile("/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established", defaultEstablishedTimeout)
	f, err := os.Open(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	counted := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		v := parseConntrackLine(sc.Text(), host, port, maxTimeout, staleGrace)
		if v.counted {
			counted++
			fmt.Printf("ACTIVE  dst=%s dport=%s\n", v.dst, v.dport)
		} else if v.dport == port || v.reason == "" || strings.HasPrefix(v.reason, "state") || strings.HasPrefix(v.reason, "stale") {
			// Only narrate lines that were plausibly RDP; skip the noise.
			fmt.Printf("skip    dst=%-15s dport=%-5s state=%-12s %s\n", v.dst, v.dport, v.state, v.reason)
		}
	}
	fmt.Printf("total counted: %d (max_timeout=%d stale_grace=%d)\n", counted, maxTimeout, staleGrace)
}
