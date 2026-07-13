#!/usr/bin/env bash
# Slime OS — linuxserver custom-init hook
# The linuxserver/wireguard image (Alpine-based, s6-overlay) doesn't ship
# redis-cli, but pair-peer.sh needs it to stash pairing codes. Runs once at
# container start, before the main WireGuard init -- verify the
# /custom-cont-init.d convention still matches current linuxserver docs at
# deploy time (it's been stable across s6-overlay v2/v3, but images do drift).
set -e
apk add --no-cache redis >/dev/null
