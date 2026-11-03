//go:build windows

package main

// Windows' own Remote Desktop control, the engine inside mstsc (hardware
// decode, camera and mic redirection), in a window of our own: slimeos-rdp.exe
// (desktop/rdp-windows), installed next to this core. Opening mstsc with a
// .rdp file brings up Windows' "Unknown remote connection" warning on every
// launch, and mstsc won't send a saved password to an NTLM-only server. The
// helper gets its settings, password included, over stdin.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

const defaultListen = "127.0.0.2:33890" // the control, like mstsc, refuses 127.0.0.1 ("console session")

func runClient(ctx context.Context, l rdpLaunch) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	settings := []string{
		"addr=" + l.Addr,
		"name=" + l.Name,
		"username=" + l.Username,
		"password=" + l.Password,
	}
	for _, s := range settings {
		if strings.ContainsAny(s, "\r\n") {
			return errors.New("invalid character in a connection setting")
		}
	}
	cmd := exec.CommandContext(ctx, filepath.Join(filepath.Dir(exe), "slimeos-rdp.exe"))
	cmd.Stdin = strings.NewReader(strings.Join(settings, "\n") + "\n")
	stderr := &lastLine{w: log.Writer()}
	cmd.Stdout = log.Writer()
	cmd.Stderr = stderr
	err = cmd.Run()
	if err == nil || ctx.Err() != nil {
		return nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		switch exit.ExitCode() {
		case 2:
			return errSignInRejected
		case 1:
			if m := stderr.String(); m != "" {
				return errors.New(m)
			}
		}
	}
	return fmt.Errorf("remote desktop: %w", err)
}

// lastLine passes output on to w and keeps its last line: the helper's
// reason for failing.
type lastLine struct {
	w    io.Writer
	mu   sync.Mutex
	last string
}

func (l *lastLine) Write(p []byte) (int, error) {
	l.mu.Lock()
	for _, line := range strings.Split(string(p), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			l.last = line
		}
	}
	l.mu.Unlock()
	return l.w.Write(p)
}

func (l *lastLine) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.TrimPrefix(l.last, "rdp: ")
}

var (
	advapi32       = windows.NewLazySystemDLL("advapi32.dll")
	procCredWriteW = advapi32.NewProc("CredWriteW")
	procCredDelete = advapi32.NewProc("CredDeleteW")
	procCredRead   = advapi32.NewProc("CredReadW")
	procCredEnum   = advapi32.NewProc("CredEnumerateW")
	procCredFree   = advapi32.NewProc("CredFree")
)

const (
	credTypeGeneric         = 1
	credPersistLocalMachine = 2
)

type credentialW struct {
	Flags              uint32
	Type               uint32
	TargetName         *uint16
	Comment            *uint16
	LastWritten        windows.Filetime
	CredentialBlobSize uint32
	CredentialBlob     *byte
	Persist            uint32
	AttributeCount     uint32
	Attributes         uintptr
	TargetAlias        *uint16
	UserName           *uint16
}

func credWrite(typ uint32, target, user, password string, persist uint32) error {
	t, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	u, err := windows.UTF16PtrFromString(user)
	if err != nil {
		return err
	}
	blob := utf16.Encode([]rune(password)) // no terminator
	if len(blob) == 0 {
		return fmt.Errorf("empty password")
	}
	c := credentialW{
		Type:               typ,
		TargetName:         t,
		CredentialBlobSize: uint32(len(blob) * 2),
		CredentialBlob:     (*byte)(unsafe.Pointer(&blob[0])),
		Persist:            persist,
		UserName:           u,
	}
	if r, _, err := procCredWriteW.Call(uintptr(unsafe.Pointer(&c)), 0); r == 0 {
		return err
	}
	return nil
}

func credDeleteType(typ uint32, target string) {
	t, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return
	}
	procCredDelete.Call(uintptr(unsafe.Pointer(t)), uintptr(typ), 0)
}
