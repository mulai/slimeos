# FreeRDP keyboard-forwarding patches

Fixes `xfreerdp3` locally intercepting keystrokes that should reach the
Brain instead. Ships in the **same rebuild** as
`membrane/freerdp/camera-patches/` (one Debian source tree, one
`dpkg-buildpackage` run, one version bump) -- see that directory's README
for the general rebuild recipe and why a rebuild is needed at all instead
of using Debian's archive `freerdp3`.

## The bug: Ctrl+Alt+M never reaches the Brain

Reported by Tommy: Google Sheets' "insert comment" shortcut (Ctrl+Alt+M)
did nothing when used inside a Windows Brain session, while Ctrl+Alt+Del
and other combos worked fine in the same session -- the asymmetry was the
tell. `xf_keyboard_handle_special_keys()` in `client/X11/xf_keyboard.c`
intercepts exactly three combos client-side, before they ever reach the
wire: Ctrl+Alt+Enter (toggle fullscreen), Ctrl+Alt+C (toggle
remote-assistance control), Ctrl+Alt+M (minimize the client window).
Ctrl+Alt+Del bypasses all of this via RDP's own separate Secure Attention
Sequence mechanism, which is why only Ctrl+Alt+M looked broken.

None of the three intercepted behaviors mean anything on this kiosk: no
window manager chrome, always fullscreen (no `/f` toggle exposed), no
remote-assistance role to swap. Every one of these combos should just
reach the Brain like any other keystroke.

## What doesn't work: `/action-script`

First attempt (2026-08-14, same day) was a flag-level fix:
`/action-script:<path>` pointed at a no-op script, on the `--help` text's
claim that output not containing `"key-local"` means "forward to the
remote." This **broke connectivity to all three Brains** (Azure/GCP/
`DESKTOP-BRCTA3T`) -- FreeRDP calls the script at PRE-CONNECT time (arg
`key`, before any RDP handshake) expecting real output regardless, and
silence is a fatal `ERRCONNECT_PRE_CONNECT_FAILED` that aborts the whole
connection attempt, not "didn't handle this keypress, please forward it."
Reverted same day (`membrane/freerdp/action-noop.sh` kept in the repo,
unwired, as a postmortem).

A second idea (wiring `xdotool` into the action-script to simulate a local
keypress) was investigated by reading the actual source
(`run_action_script()`/`xf_keyboard_execute_action_script()` in
`xf_utils.c`/`xf_keyboard.c`) rather than trusting docs a second time, and
found architecturally incapable of working: the action-script's "key" list
is populated once at pre-connect init and only lets you *substitute a
different local action* for a hotkey you explicitly register in it. The
hardcoded Ctrl+Alt+M/C/D switch in `xf_keyboard_handle_special_keys()` runs
**unconditionally** afterward regardless of what the script registered --
only Ctrl+Alt+Enter has a real disable flag (`/toggle-fullscreen`). Even
for a registered combo, the only two outputs the runtime callback
understands are `"key-local"` (no-op) or a path to a local program to run
-- there is no output value meaning "forward to the remote instead." No
flag or script combination can fix this; it needs a source patch.

## The fix

`slimeos-forward-ctrlaltm.patch` (in this dir) removes the `case XK_m:
case XK_M:` block from `xf_keyboard_handle_special_keys()`. With it gone,
Ctrl+Alt+M falls through to the same final `return FALSE` every ordinary
key hits, which is what makes `xf_keyboard_key_press()` call
`xf_keyboard_send_key()` -- a real forward of the keydown/keyup pair to
the Brain, not a locally-simulated one. Ctrl+Alt+C and Ctrl+Alt+D are left
untouched; only Ctrl+Alt+M was reported as a problem.

Verified against the actual `deb13u3`-patched Debian source (not the
upstream GitHub tag -- see camera-patches/README.md's warning about why
that distinction matters) before writing the patch: pulled the real
post-quilt source on the GCP hub, confirmed the same code at the same
location, applied the removal, and re-diffed to produce this patch.
