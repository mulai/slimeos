package main

// "Sign in with Slime ID": the slimeos.com device endpoints the Membrane
// (membrane/session/slime-id.sh) and the Android app (SlimeId.kt) use. A
// device-code sign-in approved on a phone, the account's Brain list, and a
// paid Brain's Windows sign-in. Slime ID never holds the WireGuard key: a
// Brain from the list still needs this PC's pairing to reach it.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const slimeIDAPI = "https://www.slimeos.com/api/device"

type slimeSession struct {
	Token string `json:"token"`
	Email string `json:"email"`
	Name  string `json:"name"`
}

type deviceCode struct {
	DeviceCode      string `json:"-"`
	UserCode        string `json:"userCode"`
	VerificationURI string `json:"verificationUri"`
	QR              string `json:"qr"` // data:image/png;base64,...
	ExpiresIn       int    `json:"expiresIn"`
	Interval        int    `json:"-"`
}

// remoteBrain is a Brain on the account (brains-list.ts). Kind is "free" or "paid".
type remoteBrain struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	Name string `json:"name"`
	Host string `json:"host"`
	Port int    `json:"port"`
}

type credential struct {
	Username string
	Password string
}

var errExpired = errors.New("the sign-in code expired")

func slimeIDPost(path string, body any, timeout time.Duration) (int, []byte, error) {
	b, _ := json.Marshal(body)
	c := &http.Client{Timeout: timeout}
	resp, err := c.Post(slimeIDAPI+path, "application/json", bytes.NewReader(b))
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	text, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, text, err
}

// slimeIDStart is device/start: a code to approve at slimeos.com/device.
func slimeIDStart() (*deviceCode, error) {
	code, text, err := slimeIDPost("/start", map[string]string{"label": deviceLabel()}, 10*time.Second)
	if err != nil {
		return nil, err
	}
	var r struct {
		DeviceCode      string `json:"device_code"`
		UserCode        string `json:"user_code"`
		VerificationURI string `json:"verification_uri"`
		QR              string `json:"qr_data_url"`
		ExpiresIn       int    `json:"expires_in"`
		Interval        int    `json:"interval"`
		Error           string `json:"error"`
	}
	if json.Unmarshal(text, &r) != nil || code/100 != 2 || r.DeviceCode == "" || r.UserCode == "" {
		if r.Error == "" {
			r.Error = strings.TrimSpace(string(text))
		}
		return nil, fmt.Errorf("Slime ID: HTTP %d: %.200s", code, r.Error)
	}
	if r.ExpiresIn <= 0 {
		r.ExpiresIn = 900
	}
	if r.Interval < 1 {
		r.Interval = 4
	}
	if !strings.HasPrefix(r.QR, "data:image/") {
		r.QR = ""
	}
	return &deviceCode{r.DeviceCode, r.UserCode, r.VerificationURI, r.QR, r.ExpiresIn, r.Interval}, nil
}

// slimeIDPoll is device/poll: nil, nil while still pending. Network trouble
// reads as pending too: the caller just asks again.
func slimeIDPoll(deviceCode string) (*slimeSession, error) {
	_, text, err := slimeIDPost("/poll", map[string]string{"device_code": deviceCode}, 5*time.Second)
	if err != nil {
		return nil, nil
	}
	var r struct {
		Status string `json:"status"`
		Token  string `json:"session_token"`
		User   struct {
			Email string `json:"email"`
			Name  string `json:"name"`
		} `json:"user"`
	}
	if json.Unmarshal(text, &r) != nil {
		return nil, nil
	}
	switch r.Status {
	case "approved":
		if r.Token == "" {
			return nil, errExpired
		}
		return &slimeSession{r.Token, r.User.Email, r.User.Name}, nil
	case "expired":
		return nil, errExpired
	}
	return nil, nil
}

// slimeIDLogout is best effort, like slime_id_logout(): the PC forgets the
// session either way.
func slimeIDLogout(token string) {
	slimeIDPost("/logout", map[string]string{"session_token": token}, 5*time.Second)
}

// slimeIDBrains is device/brains-list. An expired session gets an empty list.
func slimeIDBrains(token string) ([]remoteBrain, error) {
	code, text, err := slimeIDPost("/brains-list", map[string]string{"session_token": token}, 10*time.Second)
	if err != nil {
		return nil, err
	}
	if code/100 != 2 {
		return nil, fmt.Errorf("Slime ID: HTTP %d", code)
	}
	var r struct {
		Brains []struct {
			ID   string          `json:"id"`
			Kind string          `json:"kind"`
			Name string          `json:"name"`
			Host *string         `json:"host"`
			Port json.RawMessage `json:"port"`
		} `json:"brains"`
	}
	if err := json.Unmarshal(text, &r); err != nil {
		return nil, err
	}
	list := []remoteBrain{}
	for _, b := range r.Brains {
		host := ""
		if b.Host != nil {
			host = strings.TrimSpace(*b.Host)
		}
		port := 3389
		if p := strings.Trim(strings.TrimSpace(string(b.Port)), `"`); p != "" && p != "null" {
			n, err := strconv.Atoi(p)
			if err != nil {
				continue
			}
			port = n
		}
		// Server data: only well-formed addresses reach the picker (#37).
		if b.ID == "" || !validHost(host) || port < 1 || port > 65535 {
			continue
		}
		kind := b.Kind
		if kind == "" {
			kind = "free"
		}
		name := strings.TrimSpace(b.Name)
		if name == "" {
			name = "Untitled Brain"
		}
		list = append(list, remoteBrain{b.ID, kind, name, host, port})
	}
	return list, nil
}

// slimeIDCredential is device/brain-credential: a paid Brain's Windows
// sign-in, fetched fresh before a connect and never stored.
func slimeIDCredential(token, brainID string) (*credential, error) {
	code, text, err := slimeIDPost("/brain-credential",
		map[string]string{"session_token": token, "brainId": brainID}, 10*time.Second)
	if err != nil {
		return nil, err
	}
	var r struct {
		OK       bool   `json:"ok"`
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if json.Unmarshal(text, &r) != nil || code/100 != 2 || !r.OK || r.Password == "" {
		return nil, fmt.Errorf("Slime ID has no sign-in for this Brain (HTTP %d)", code)
	}
	return &credential{r.Username, r.Password}, nil
}

var hostNameRE = regexp.MustCompile(`^(?:(?:\d{1,3}\.){3}\d{1,3}|[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)$`)

func validHost(h string) bool { return h != "" && len(h) <= 253 && hostNameRE.MatchString(h) }

// deviceLabel names this PC on slimeos.com/device and in the account's device list.
func deviceLabel() string {
	h, _ := os.Hostname()
	h = strings.TrimSpace(h)
	if h == "" {
		h = "Slime OS desktop"
	}
	if len(h) > 40 {
		h = h[:40]
	}
	return h
}

func sessionPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "SlimeOS", "slime-id.json"), nil
}

func loadSession() *slimeSession {
	path, err := sessionPath()
	if err != nil {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var s slimeSession
	if json.Unmarshal(b, &s) != nil || s.Token == "" {
		return nil
	}
	return &s
}

func saveSession(s *slimeSession) error {
	path, err := sessionPath()
	if err != nil {
		return err
	}
	if s == nil {
		err := os.Remove(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, _ := json.Marshal(s)
	return os.WriteFile(path, b, 0o600)
}
