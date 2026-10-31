//go:build !windows

package main

// FreeRDP's SDL client on macOS (bundled in the app) and Linux (the
// distribution's). Arguments go over stdin (/args-from:stdin), so the
// password never shows in the process list.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// macOS only has 127.0.0.1 on lo0.
const defaultListen = "127.0.0.1:33890"

func runClient(ctx context.Context, l rdpLaunch) error {
	bin, err := findFreeRDP()
	if err != nil {
		return err
	}
	args := []string{
		"/v:" + l.Addr,
		// The tunnel already proves which Brain this is; its certificate is
		// self-signed and names the Brain, not the loopback address.
		"/cert:ignore",
		"/title:" + l.Name,
		"/f", // like mstsc; Right Shift + Return switches to a window
		"/bpp:32",
		"/network:auto",
		"+auto-reconnect",
		"/sound",
		"/microphone",
		"+clipboard",
	}
	if runtime.GOOS == "darwin" {
		// The bundled FreeRDP decodes H.264 with VideoToolbox and passes the
		// camera through AVFoundation (.github/workflows/desktop.yml).
		// "AVC420" keeps AVC444v2 off (3.32.2's FFmpeg path decoded it but
		// never showed a frame); Windows still sends full-colour AVC444v1.
		args = append(args, "/gfx:AVC420", "/dvc:rdpecam")
	} else {
		args = append(args, "/gfx:AVC444")
	}
	if w, h, ok := screenPoints(); ok {
		// The session at the screen's size in points, scaled up to the
		// pixels: a quarter of the work of a full Retina desktop for
		// FreeRDP's SDL renderer (smooth video, sound in step), at Windows'
		// own 100%. Smart sizing also makes the window resizable, which
		// macOS full screen needs.
		args = append(args, fmt.Sprintf("/smart-sizing:%dx%d", w, h))
	} else {
		args = append(args, "/dynamic-resolution")
		// Windows starts at 100% unless told; a Retina screen is 200%.
		if l.Scale > 100 && l.Scale <= 500 {
			args = append(args, fmt.Sprintf("/scale-desktop:%d", l.Scale))
		}
	}
	if l.Username != "" {
		args = append(args, "/u:"+l.Username)
	}
	if l.Password != "" {
		args = append(args, "/p:"+l.Password)
	}
	for _, a := range args {
		if strings.ContainsAny(a, "\r\n") {
			return errors.New("invalid character in a connection setting")
		}
	}
	cmd := exec.CommandContext(ctx, bin, "/args-from:stdin")
	cmd.Stdin = strings.NewReader(strings.Join(args, "\n") + "\n")
	// Into desktop.log too (our stdout is the app's protocol). INFO says
	// which H.264 decoder runs; FreeRDP never logs the password.
	cmd.Stdout = log.Writer()
	cmd.Stderr = log.Writer()
	cmd.Env = os.Environ()
	if os.Getenv("WLOG_LEVEL") == "" {
		cmd.Env = append(cmd.Env, "WLOG_LEVEL=INFO")
	}
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		var exit *exec.ExitError
		// FreeRDP exits non-zero for a plain disconnect or sign-out too
		// (freerdp/error.h's client exit codes); only the rest are failures.
		if errors.As(err, &exit) {
			switch exit.ExitCode() {
			case 0, 1, 2, 3, 4, 5, 12:
				return nil
			case 132, 134, 154, 159: // auth / logon failure, wrong password, no credentials
				return errSignInRejected
			}
			return &clientExit{exit.ExitCode()}
		}
		return fmt.Errorf("FreeRDP: %w", err)
	}
	return nil
}

type clientExit struct{ code int }

func (e *clientExit) Error() string { return fmt.Sprintf("FreeRDP exited with code %d", e.code) }

// findFreeRDP: SLIMEOS_FREERDP, then the copy bundled in the macOS app
// (Contents/Helpers/FreeRDP.app, see desktop/app/package-macos.sh; this
// runs from Contents/MacOS), then the system's.
func findFreeRDP() (string, error) {
	if p := os.Getenv("SLIMEOS_FREERDP"); p != "" {
		return p, nil
	}
	if exe, err := os.Executable(); err == nil && runtime.GOOS == "darwin" {
		p := filepath.Join(filepath.Dir(exe), "..", "Helpers", "FreeRDP.app", "Contents", "MacOS", "sdl-freerdp")
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	for _, name := range []string{"sdl-freerdp3", "sdl-freerdp", "xfreerdp3", "xfreerdp"} {
		if p, err := exec.LookPath(name); err == nil {
			return p, nil
		}
	}
	return "", errors.New("FreeRDP isn't installed")
}
