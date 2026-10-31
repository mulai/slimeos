//go:build !darwin && !windows

package main

// Linux: nothing remembered yet; the window asks every time.

import "errors"

func loadSignIn(string) (credential, bool) { return credential{}, false }

func saveSignIn(string, credential) error { return errors.New("not supported on this system") }

func forgetSignIn(string) {}

func forgetAllSignIns() {}
