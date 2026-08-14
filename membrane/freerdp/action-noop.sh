#!/bin/sh
# Slime OS — FreeRDP action-script: NOT currently wired up, kept as a
# postmortem for the next attempt.
#
# Goal (still unsolved): without an /action-script, xfreerdp3 intercepts
# a handful of Ctrl+Alt+<key> combinations itself instead of forwarding
# them to the remote session: Ctrl+Alt+Enter (toggle fullscreen),
# Ctrl+Alt+C (toggle remote-assistance control), Ctrl+Alt+M (minimize the
# client window). Confirmed live 2026-08-14: a Google Sheets "insert
# comment" shortcut (also Ctrl+Alt+M) inside a Windows Brain session
# never arrived because of this. None of those local behaviors mean
# anything on this kiosk (no window manager chrome, always fullscreen via
# /f, no remote-assistance role to swap) -- every one of these
# combinations should just reach the Brain like any other keystroke.
#
# What was tried and reverted the same day: pointing /action-script at
# this file with a bare `exit 0` (no stdout), on the --help text's
# description that output NOT containing "key-local" means "forward to
# the remote". That's wrong, or at least incomplete -- confirmed live
# against all three Brains (Azure/GCP/DESKTOP-BRCTA3T), FreeRDP calls
# this script at PRE-CONNECT time (before any RDP handshake at all, with
# argument "key") expecting SOME output, and treats no output as a fatal
# `[ActionScript] No data returned from command` error that aborts the
# whole connection attempt (ERRCONNECT_PRE_CONNECT_FAILED, exit 136) --
# not merely "didn't handle this specific keypress, please forward it".
# connect.sh no longer references this file. Before retrying: read
# FreeRDP's actual C source for run_action_script() (client/common/
# actions.c or similar in the freerdp3 source, not just --help) to learn
# the real expected output format/protocol, and test against a
# disposable Brain or a VM first -- not blind against Tommy's three
# production Brains again.
exit 0
