#!/usr/bin/env bash
# Slime OS — WireGuard self-service pairing code generator
#
# Generates a peer (via provision-peer.sh, not duplicated here) and stashes
# its config in Redis behind a short-lived, single-use pairing code, so an
# end user can self-enroll their Membrane device by typing the code into the
# lock screen instead of an admin hand-copying wg0.conf over USB/rescue-mode.
#
# This is part of the open-source, account-free Connect path — it does NOT
# go through Authelia or dashboard.slimeos.com (that's reserved for the
# separate, not-yet-built "Sign in with Slime ID" managed path).
#
# Usage:
#   docker exec slimeos-wireguard /config/pair-peer.sh <device-name>
#
# The resulting code is meant to be relayed to the end user out-of-band
# (voice/chat/etc) and typed into the Membrane's "Pair with a Brain" screen.

set -euo pipefail

PEER_NAME="${1:-membrane-$(date +%s)}"
PEER_DIR="/config/peer_${PEER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root inside the WireGuard container"
[[ -n "${REDIS_PASSWORD:-}" ]] || die "REDIS_PASSWORD env var not set — is this running inside the slimeos-wireguard container?"
command -v redis-cli &>/dev/null || die "redis-cli not found — check the custom-init hook that installs it"

"$SCRIPT_DIR/provision-peer.sh" "$PEER_NAME" >&2

CONFIG_FILE="$PEER_DIR/wg0.conf"
[[ -f "$CONFIG_FILE" ]] || die "provision-peer.sh did not produce $CONFIG_FILE"

# Crockford-safe alphabet (excludes 0/O/1/I/L) -- unambiguous read aloud or
# hand-typed on the kiosk's on-screen/physical keyboard. 8 chars ~= 40 bits
# of entropy; combined with single-use + a short TTL below, that's plenty
# against network brute force -- the TTL is the real control, not the length.
# `set +o pipefail` inside the substitution only (same fix as install.sh's
# RECOVERY_PIN generation): head -c 8 closing early sends tr SIGPIPE, which
# pipefail would otherwise turn into a whole-script abort under set -e.
CODE=$(set +o pipefail; tr -dc 'ABCDEFGHJKMNPQRSTVWXYZ23456789' < /dev/urandom | head -c 8)
CODE_DISPLAY="${CODE:0:4}-${CODE:4:4}"

# TTL 900s (15 min): long enough for an admin to relay the code and the user
# to type it, short enough that a leaked/overheard code is worthless soon
# after. SET ... EX is a single atomic write -- no separate EXPIRE call.
redis-cli -h redis -a "$REDIS_PASSWORD" --no-auth-warning \
    SET "pair:${CODE}" "$(cat "$CONFIG_FILE")" EX 900 >/dev/null

echo ""
echo "  ✓ Pairing code for '${PEER_NAME}': ${CODE_DISPLAY}"
echo "  ✓ Expires in 15 minutes, single use"
echo ""
echo "  On the Membrane's lock screen, use \"Pair with a Brain\" (gear-adjacent"
echo "  icon) and enter this code plus your enrollment host, e.g.:"
echo "    enroll.slimeos.com"
echo ""
