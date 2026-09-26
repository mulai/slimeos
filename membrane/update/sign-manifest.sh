#!/usr/bin/env bash
# Slime OS — sign manifest.json for release (maintainer's machine only)
#
# Run after the last edit to manifest.json, commit manifest.json.sig with it.
# Devices check the signature in apply-update-helper.sh against the keys
# pinned there (#39). Uses the primary key from the ssh-agent (on macOS the
# passphrase comes from Keychain). For the offline backup key, copy it off
# the stick, chmod 600 it, and point SLIMEOS_SIGNING_KEY at it:
#   SLIMEOS_SIGNING_KEY=/path/to/slimeos_release_backup membrane/update/sign-manifest.sh
set -euo pipefail

cd "$(dirname "$0")"
KEY="${SLIMEOS_SIGNING_KEY:-$HOME/.ssh/slimeos_release}"
NAMESPACE="slimeos-update"
SIGNER_ID="release@slimeos"

jq -e . manifest.json >/dev/null || { echo "manifest.json is not valid JSON" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] && ssh-add --apple-load-keychain >/dev/null 2>&1 || true

rm -f manifest.json.sig
ssh-keygen -q -Y sign -f "$KEY" -n "$NAMESPACE" manifest.json

# Check it the way a device will, with the keys pinned in the helper.
signers=$(mktemp)
trap 'rm -f "$signers"' EXIT
grep "^$SIGNER_ID " apply-update-helper.sh > "$signers"
ssh-keygen -Y verify -f "$signers" -I "$SIGNER_ID" -n "$NAMESPACE" -s manifest.json.sig < manifest.json
