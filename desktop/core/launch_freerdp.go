//go:build !windows

package main

// FreeRDP's SDL client on macOS (bundled in the app) and Linux (the
// distribution's). Arguments go over stdin (/args-from:stdin), so the
// password never shows in the process list.

import (
	"context"
	"errors"
	"fmt"
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
		"/size:85%",
		"/dynamic-resolution",
		"/gfx:AVC444",
		"/bpp:32",
		"/network:auto",
		"+auto-reconnect",
		"/sound",
		"/microphone",
		"+clipboard",
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
	cmd.Stdout = os.Stderr // our stdout is the app's protocol
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		var exit *exec.ExitError
		// FreeRDP exits non-zero for a plain disconnect or sign-out too
		// (freerdp/error.h's client exit codes); only the rest are failures.
		if errors.As(err, &exit) {
			switch exit.ExitCode() {
			case 0, 1, 2, 3, 4, 5, 12:
				return nil
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
