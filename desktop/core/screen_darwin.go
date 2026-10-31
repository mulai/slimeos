package main

// The screen's size in points below the notch, which is what macOS gives a
// full-screen window. NSScreen through JavaScript for Automation: no cgo.

import (
	"encoding/json"
	"os/exec"
)

const screenScript = `ObjC.import("AppKit");
const s = $.NSScreen.mainScreen;
JSON.stringify({w: s.frame.size.width, h: s.frame.size.height, top: s.safeAreaInsets.top})`

func screenPoints() (w, h int, ok bool) {
	out, err := exec.Command("/usr/bin/osascript", "-l", "JavaScript", "-e", screenScript).Output()
	if err != nil {
		return 0, 0, false
	}
	var s struct{ W, H, Top float64 }
	if json.Unmarshal(out, &s) != nil {
		return 0, 0, false
	}
	w, h = int(s.W), int(s.H-s.Top)
	w, h = w&^1, h&^1 // even, as FreeRDP sizes its desktop
	if w < 640 || h < 480 {
		return 0, 0, false
	}
	return w, h, true
}
