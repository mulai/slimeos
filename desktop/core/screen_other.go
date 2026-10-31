//go:build !darwin && !windows

package main

// Linux: FreeRDP follows the window (/dynamic-resolution).
func screenPoints() (w, h int, ok bool) { return 0, 0, false }
