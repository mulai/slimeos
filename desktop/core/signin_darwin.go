package main

// Remembered Windows sign-ins on macOS: the login Keychain, one item per
// Brain (service "Slime OS", account = Brain ID), written and read with
// /usr/bin/security. Commands go over its stdin (-i), so the password never
// shows in the process list.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
)

const keychainService = "Slime OS"

var keychainAccount = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

func loadSignIn(brainID string) (credential, bool) {
	var c credential
	if !keychainAccount.MatchString(brainID) {
		return c, false
	}
	out, err := exec.Command("/usr/bin/security", "find-generic-password",
		"-s", keychainService, "-a", brainID, "-w").Output()
	if err != nil {
		return c, false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil || json.Unmarshal(raw, &c) != nil || c.Username == "" {
		return credential{}, false
	}
	return c, true
}

func saveSignIn(brainID string, c credential) error {
	if !keychainAccount.MatchString(brainID) {
		return errors.New("unexpected Brain ID")
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return err
	}
	cmd := exec.Command("/usr/bin/security", "-i")
	cmd.Stdin = strings.NewReader(fmt.Sprintf("add-generic-password -U -s %q -a %s -l %q -w %s\n",
		keychainService, brainID, keychainService, base64.StdEncoding.EncodeToString(raw)))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	if _, ok := loadSignIn(brainID); !ok { // security -i exits 0 even when a command fails
		return errors.New("the Keychain didn't keep it")
	}
	return nil
}

func forgetSignIn(brainID string) {
	if keychainAccount.MatchString(brainID) {
		exec.Command("/usr/bin/security", "delete-generic-password", "-s", keychainService, "-a", brainID).Run()
	}
}

func forgetAllSignIns() {
	// delete-generic-password removes one match per call.
	for i := 0; i < 100; i++ {
		if exec.Command("/usr/bin/security", "delete-generic-password", "-s", keychainService).Run() != nil {
			return
		}
	}
}
