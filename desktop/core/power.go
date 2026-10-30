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

// wakeAndWait wakes host and waits until its RDP port answers. Azure reports
// a VM "running" well before Windows listens, so the port probe comes last.
func (t *tunnel) wakeAndWait(ctx context.Context, host string, port int) error {
	target := host + ":" + strconv.Itoa(port)
	for {
		state, err := t.wakeOnce(host)
		switch {
		case errors.Is(err, errNotAllowed):
			return err
		case err != nil:
			log.Printf("wake %s: %v (retrying)", host, err)
		case state == "failed":
			return errors.New("the Brain failed to start")
		case state == "running" || state == "unmanaged":
			dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			c, err := t.dial(dctx, target)
			cancel()
			if err == nil {
				c.Close()
				return nil
			}
			log.Printf("wake %s: %s, RDP not answering yet", host, state)
		default:
			log.Printf("wake %s: %s", host, state)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
}
