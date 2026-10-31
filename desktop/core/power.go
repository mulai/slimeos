package main

// Waking a Brain: same protocol as connect.sh's wake_brain() and the
// Android app's BrainPower.kt. brain/power on the hub answers /wake over the
// tunnel; a managed Brain that's asleep needs the wake and a few polls
// before RDP answers, an unmanaged one is just "go ahead".

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const powerURL = "http://10.10.0.1:7677"

var errNotAllowed = errors.New("this device isn't allowed to wake that Brain")

// wakeOnce returns the Brain's state: "running", "starting", "cleaning",
// "restarting", "failed" (or another Azure power state), or "unmanaged".
func (t *tunnel) wakeOnce(host string) (string, error) {
	body, _ := json.Marshal(map[string]string{"host": host})
	resp, err := t.httpClient(10*time.Second).Post(powerURL+"/wake", "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	// A 403 carries no "managed" field, which must not read as "unmanaged,
	// go ahead": a managed Brain that's asleep would then just time out.
	if resp.StatusCode == http.StatusForbidden {
		return "", errNotAllowed
	}
	var r struct {
		Managed bool   `json:"managed"`
		State   string `json:"state"`
	}
	if err := json.Unmarshal(text, &r); err != nil {
		return "", fmt.Errorf("wake: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(text)))
	}
	if !r.Managed {
		return "unmanaged", nil
	}
	return r.State, nil
}

var errUnreachable = errors.New("this PC's pairing doesn't reach that Brain")

// wakeAndWait wakes host and waits until its RDP port answers, reporting each
// step to progress (Android's waitForBrainAwake). Azure reports a VM
// "running" well before Windows listens, so the port probe comes last.
func (t *tunnel) wakeAndWait(ctx context.Context, host string, port int, progress func(string)) error {
	target := host + ":" + strconv.Itoa(port)
	listening := func() bool {
		dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		c, err := t.dial(dctx, target)
		if err == nil {
			c.Close()
		}
		return err == nil
	}
	// Covers a wake from deallocated and a frozen-Brain restart (up to ~5 min).
	start := time.Now()
	deadline := start.Add(8 * time.Minute)
	sawRunning := false
	unanswered := 0
	for time.Now().Before(deadline) {
		state, err := t.wakeOnce(host)
		wait := 5 * time.Second
		switch {
		case errors.Is(err, errNotAllowed):
			// Only waking is refused: an awake Brain still connects.
			if listening() {
				return nil
			}
			return err
		case err == nil && state == "failed":
			return errors.New("the Brain failed to start")
		case err == nil && (state == "running" || state == "unmanaged"):
			if listening() {
				return nil
			}
			if state == "unmanaged" {
				// Nothing on the hub will start it: it's off, or not on this tunnel.
				if unanswered++; unanswered >= 3 {
					return errUnreachable
				}
			} else {
				sawRunning = true
				progress("Brain is up. Starting the desktop…")
			}
			wait = 3 * time.Second
		case err == nil && state == "restarting":
			progress("Restarting your Brain… (about 2 minutes)")
		case err == nil && state == "cleaning":
			progress("Finishing your last session…")
		default:
			if err != nil {
				log.Printf("wake %s: %v (retrying)", host, err)
			}
			// Elapsed time, not a poll count: "attempt 13" read as 13 failures.
			s := int(time.Since(start).Seconds())
			progress(fmt.Sprintf("Waking up your Brain… This usually takes 1–2 minutes (%d:%02d)", s/60, s%60))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
	// Running all along but never listening: connect anyway and let the client say why.
	if sawRunning {
		return nil
	}
	return errors.New("the Brain didn't wake up within 8 minutes")
}
