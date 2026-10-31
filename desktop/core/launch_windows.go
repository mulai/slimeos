//go:build windows

package main

// Windows' own client, mstsc: the best RDP client on Windows (hardware
// decode, multi-monitor, camera and mic redirection). It reads its settings
// from a .rdp file, and the sign-in from Credential Manager (TERMSRV/<host>,
// the entry mstsc's own "Remember me" writes), so the password is never on a
// command line or in a file. Both are removed again when mstsc exits.

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

const defaultListen = "127.0.0.2:33890" // mstsc refuses 127.0.0.1 ("console session")

func runClient(ctx context.Context, l rdpLaunch) error {
	host, _, err := net.SplitHostPort(l.Addr)
	if err != nil {
		return err
	}
	if l.Password != "" {
		target := "TERMSRV/" + host
		if err := credWrite(credTypeDomainPassword, target, l.Username, l.Password, credPersistSession); err != nil {
			log.Printf("Credential Manager: %v (mstsc will ask)", err)
		} else {
			defer credDelete(target)
		}
	}
	dir := filepath.Join(os.TempDir(), "SlimeOS")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// mstsc puts the file name in its title bar.
	path := filepath.Join(dir, fileSafe(l.Name)+".rdp")
	if err := os.WriteFile(path, rdpFile(l), 0o600); err != nil {
		return err
	}
	defer os.Remove(path)
	mstsc := filepath.Join(os.Getenv("SystemRoot"), "System32", "mstsc.exe")
	cmd := exec.CommandContext(ctx, mstsc, path)
	if err := cmd.Run(); err != nil && ctx.Err() == nil {
		return fmt.Errorf("mstsc: %w", err)
	}
	return nil
}

// rdpFile is UTF-16LE with a BOM, as mstsc itself saves them.
func rdpFile(l rdpLaunch) []byte {
	lines := []string{
		"full address:s:" + l.Addr,
		"prompt for credentials:i:0",
		// The tunnel already proves which Brain this is; its certificate is
		// self-signed and names the Brain, not the loopback address.
		"authentication level:i:0",
		"enablecredsspsupport:i:1",
		"screen mode id:i:2",
		"smart sizing:i:1",
		"dynamic resolution:i:1",
		"connection type:i:7",
		"networkautodetect:i:1",
		"bandwidthautodetect:i:1",
		"autoreconnection enabled:i:1",
		"videoplaybackmode:i:1",
		"audiomode:i:0",
		"audiocapturemode:i:1",
		"camerastoredirect:s:*",
		"redirectclipboard:i:1",
		"redirectprinters:i:0",
	}
	if l.Username != "" {
		lines = append(lines, "username:s:"+l.Username)
	}
	u := utf16.Encode([]rune(strings.Join(lines, "\r\n") + "\r\n"))
	b := []byte{0xFF, 0xFE}
	for _, c := range u {
		b = append(b, byte(c), byte(c>>8))
	}
	return b
}

func fileSafe(name string) string {
	s := strings.Map(func(r rune) rune {
		if strings.ContainsRune(`<>:"/\|?*`, r) || r < 32 {
			return '-'
		}
		return r
	}, strings.TrimSpace(name))
	if s == "" {
		s = "Brain"
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
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
	credTypeGeneric        = 1
	credTypeDomainPassword = 2

	credPersistSession      = 1 // gone at sign-out even if we never delete it
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

func credDelete(target string) { credDeleteType(credTypeDomainPassword, target) }

func credDeleteType(typ uint32, target string) {
	t, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return
	}
	procCredDelete.Call(uintptr(unsafe.Pointer(t)), uintptr(typ), 0)
}
