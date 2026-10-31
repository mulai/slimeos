package main

// Remembered Windows sign-ins on Windows: Credential Manager, one generic
// entry per Brain ("SlimeOS/<Brain ID>", shown under Windows Credentials).

import (
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

const signInPrefix = "SlimeOS/"

func loadSignIn(brainID string) (credential, bool) {
	t, err := windows.UTF16PtrFromString(signInPrefix + brainID)
	if err != nil {
		return credential{}, false
	}
	var p *credentialW
	if r, _, _ := procCredRead.Call(uintptr(unsafe.Pointer(t)), credTypeGeneric, 0, uintptr(unsafe.Pointer(&p))); r == 0 {
		return credential{}, false
	}
	defer procCredFree.Call(uintptr(unsafe.Pointer(p)))
	blob := unsafe.Slice((*uint16)(unsafe.Pointer(p.CredentialBlob)), p.CredentialBlobSize/2)
	c := credential{windows.UTF16PtrToString(p.UserName), string(utf16.Decode(blob))}
	return c, c.Username != ""
}

func saveSignIn(brainID string, c credential) error {
	return credWrite(credTypeGeneric, signInPrefix+brainID, c.Username, c.Password, credPersistLocalMachine)
}

func forgetSignIn(brainID string) { credDeleteType(credTypeGeneric, signInPrefix+brainID) }

func forgetAllSignIns() {
	filter, err := windows.UTF16PtrFromString(signInPrefix + "*")
	if err != nil {
		return
	}
	var n uint32
	var list **credentialW
	if r, _, _ := procCredEnum.Call(uintptr(unsafe.Pointer(filter)), 0,
		uintptr(unsafe.Pointer(&n)), uintptr(unsafe.Pointer(&list))); r == 0 {
		return
	}
	defer procCredFree.Call(uintptr(unsafe.Pointer(list)))
	for _, c := range unsafe.Slice(list, n) {
		if c.Type == credTypeGeneric {
			credDeleteType(credTypeGeneric, windows.UTF16PtrToString(c.TargetName))
		}
	}
}
