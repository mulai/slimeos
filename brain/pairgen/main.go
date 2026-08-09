// Slime OS — Self-service pairing-code generator for purchased resources
//
// Gives slimeos.com's Cloudflare Worker (which cannot SSH into this host)
// an HTTPS API to do what an admin previously had to do by hand: run
// pair-peer.sh and hand the resulting code to a customer. Reachable via
// Caddy at pairgen.slimeos.com -- unlike brain/power/main.go (which binds
// only the wg0 address so WireGuard membership IS the auth), a Cloudflare
// Worker is not a WireGuard peer, so this needs a real bearer-token check
// instead of relying on network position.
//
// network_mode: service:wireguard (see docker-compose.yml) for the same
// reason brain/power has it: pair-peer.sh needs to run `wg`/`wg-quick`
// against the live wg0 interface, which needs this process sharing
// WireGuard's network namespace and NET_ADMIN capability. Sharing that
// namespace also means Caddy reaches this service as `wireguard:<port>`,
// not `pairgen:<port>` -- this container has no independent network
// identity of its own (see docker-compose.yml's `pairgen:` comment).
//
// Deliberately execs the EXISTING pair-peer.sh rather than reimplementing
// peer provisioning in Go: one script, one place peer-minting logic lives,
// the same script an admin would still run by hand for anything this
// doesn't cover.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"time"
)

var codeRe = regexp.MustCompile(`Pairing code for '[^']*':\s*(\S+)`)
var deviceNameRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)

// Matches pair-peer.sh's own SET ... EX 900 -- reported back to the caller,
// not enforced here (the code's real expiry lives in Redis).
const pairingCodeTTLSeconds = 900

// Bare hostname, no scheme -- this is what gets typed into the kiosk's
// "Enrollment host" field on the pairEntry screen (pair.sh's own
// do_pair() builds "https://${host}/pair" itself; a scheme here would
// double up into an invalid URL).
const enrollmentHost = "enroll.slimeos.com"

func main() {
	listen := flag.String("listen", ":8090", "address to listen on (reachable via Caddy as wireguard:<port> -- see docker-compose.yml's network_mode)")
	scriptPath := flag.String("script", "/config/pair-peer.sh", "path to pair-peer.sh")
	flag.Parse()

	secret := os.Getenv("PAIRGEN_SHARED_SECRET")
	if secret == "" {
		log.Fatal("PAIRGEN_SHARED_SECRET is not set")
	}

	s := &server{secret: secret, scriptPath: *scriptPath}

	mux := http.NewServeMux()
	mux.HandleFunc("/generate", s.handleGenerate)

	log.Printf("slimeos-pairgen listening on %s (script=%s)", *listen, *scriptPath)
	log.Fatal(http.ListenAndServe(*listen, mux))
}

type server struct {
	secret     string
	scriptPath string
}

type generateRequest struct {
	DeviceName string `json:"device_name"`
}

type generateResponse struct {
	OK             bool   `json:"ok"`
	Code           string `json:"code,omitempty"`
	EnrollmentHost string `json:"enrollment_host,omitempty"`
	ExpiresIn      int    `json:"expires_in,omitempty"`
	Error          string `json:"error,omitempty"`
}

func (s *server) handleGenerate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// This bearer token is the ENTIRE authorization boundary for a
	// privileged, peer-minting endpoint -- see the file header on why
	// network position (brain/power's approach) can't do that job here.
	// Constant-time comparison since a leaked/guessed token lets an
	// attacker mint arbitrary WireGuard peers on this hub.
	const prefix = "Bearer "
	auth := r.Header.Get("Authorization")
	if len(auth) <= len(prefix) || auth[:len(prefix)] != prefix {
		writeJSON(w, http.StatusUnauthorized, generateResponse{Error: "unauthorized"})
		return
	}
	if subtle.ConstantTimeCompare([]byte(auth[len(prefix):]), []byte(s.secret)) != 1 {
		writeJSON(w, http.StatusUnauthorized, generateResponse{Error: "unauthorized"})
		return
	}

	var req generateRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, generateResponse{Error: "bad_request"})
		return
	}
	// exec.CommandContext never goes through a shell, so this isn't an
	// injection guard -- it's here because provision-peer.sh writes
	// device_name into `/config/peer_${PEER_NAME}` (a filesystem path) and
	// a `# Peer: ${PEER_NAME}` comment line in wg0.conf, and an unrestricted
	// value could still smuggle path traversal or stray config-file content
	// into either.
	if !deviceNameRe.MatchString(req.DeviceName) {
		writeJSON(w, http.StatusBadRequest, generateResponse{Error: "invalid_device_name"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, s.scriptPath, req.DeviceName)
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("pair-peer.sh %s failed: %v\n%s", req.DeviceName, err, snippet(out))
		writeJSON(w, http.StatusInternalServerError, generateResponse{Error: "provisioning_failed"})
		return
	}

	m := codeRe.FindSubmatch(out)
	if m == nil {
		log.Printf("pair-peer.sh %s produced no parseable code:\n%s", req.DeviceName, snippet(out))
		writeJSON(w, http.StatusInternalServerError, generateResponse{Error: "provisioning_failed"})
		return
	}

	log.Printf("generated pairing code for device_name=%s", req.DeviceName)
	writeJSON(w, http.StatusOK, generateResponse{
		Code:           string(m[1]),
		EnrollmentHost: enrollmentHost,
		ExpiresIn:      pairingCodeTTLSeconds,
	})
}

func writeJSON(w http.ResponseWriter, status int, v generateResponse) {
	if status == http.StatusOK {
		v.OK = true
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func snippet(b []byte) string {
	s := string(b)
	if len(s) > 500 {
		s = s[:500] + "…"
	}
	return s
}
