#!/usr/bin/env bash
# Slime OS — "Sign in with Slime ID" device-code login
#
# `source`d by membrane/session/coordinator.sh, same shape as pair.sh's
# do_pair(): relies on coordinator.sh's own log()/emit_state()/read_event()
# helpers. Unlike do_pair()/do_network_setup()/do_support(), this has no
# `mode` ("boot" vs "settings") -- it's a direct user-initiated action from
# the empty/picker screen's button, not boot-gated and not part of the
# tabbed Settings panel.
#
# This is deliberately scoped to JUST the login handshake (agreed with
# Tommy 2026-08-09) -- it proves identity and stores a session token, full
# stop. No brain listing, no WireGuard peer auto-provisioning: that's the
# separate, explicitly-deferred managed-provisioning work docs/
# architecture.md and the project backlog both flag as "not yet built."
#
# Shape: an OAuth-device-grant-style flow (RFC 8628), closely modeled on
# the existing WireGuard pairing flow (pair.sh + brain/enroll/) but
# poll-until-approved rather than pair.sh's fetch-once -- the user
# completes login/approval on their own phone/laptop (scanning a QR or
# typing a short code + URL) while the kiosk polls in the background. The
# polling sub-loop below uses the exact interruptible-wait idiom connect.sh's
# Azure wake-wait loop already established (`read -t 1` in a 1s-sliced
# loop, only actually curling every Nth tick), so Back and power-off still
# work while waiting, not just at the top.
#
# Phases (same two-levels-deep shape as do_pair()):
#   "starting" -- POSTs /api/device/start, gets a device_code/user_code/QR.
#   "waiting"  -- shows the QR/code, polls /api/device/poll until
#                 approved/expired/cancelled.
# Any failure in either phase falls through to a shared error sub-loop
# (retry re-enters "starting" with a fresh code, same as pairError's retry).

SLIME_ID_API="https://www.slimeos.com/api"
SLIME_ID_SESSION_FILE="$CONFIG_DIR/slime-id-session"

do_slime_id_login() {
    local phase="starting"
    local device_code="" user_code="" verification_uri="" qr_data_url="" expires_in=900 interval=4

    while true; do
        if [[ "$phase" == "starting" ]]; then
            emit_state slimeIdConnecting '{"stage":"Preparing sign-in…"}'

            set +e
            local response exit_code
            response=$(curl -fsS -m 10 -X POST "$SLIME_ID_API/device/start" 2>&1)
            exit_code=$?
            set -e

            if [[ $exit_code -eq 0 ]]; then
                device_code=$(jq -r '.device_code // empty' <<<"$response" 2>/dev/null)
                user_code=$(jq -r '.user_code // empty' <<<"$response" 2>/dev/null)
                verification_uri=$(jq -r '.verification_uri // empty' <<<"$response" 2>/dev/null)
                qr_data_url=$(jq -r '.qr_data_url // empty' <<<"$response" 2>/dev/null)
                expires_in=$(jq -r '.expires_in // 900' <<<"$response" 2>/dev/null)
                interval=$(jq -r '.interval // 4' <<<"$response" 2>/dev/null)
            fi

            if [[ $exit_code -ne 0 || -z "$device_code" || -z "$user_code" ]]; then
                log "Slime ID device/start failed (exit $exit_code): $response"
                emit_state slimeIdError "$(jq -nc --arg d "$response" \
                    '{message:"Couldn'"'"'t reach Slime ID right now.", detail:$d}')"
            else
                phase="waiting"
                continue
            fi
        fi

        if [[ "$phase" == "waiting" ]]; then
            emit_state slimeIdEntry "$(jq -nc --arg u "$user_code" --arg v "$verification_uri" --arg q "$qr_data_url" \
                '{userCode:$u, verificationUri:$v, qrDataUrl:$q}')"

            local waited=0 outcome="timeout" approved_response=""
            while (( waited < expires_in )); do
                if read -t 1 -r line <&0; then
                    local ev_type
                    ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                    case "$ev_type" in
                        back) outcome="cancelled"; break ;;
                        forceBack) return 0 ;;
                        *)
                            try_handle_power_event "$ev_type" || :
                            try_handle_crash_report "$ev_type" "$line" || :
                            ;;
                    esac
                else
                    local rc=$?
                    if (( rc <= 128 )); then
                        log "stdin closed during Slime ID poll — exiting"
                        exit 0
                    fi
                fi
                waited=$((waited + 1))
                (( waited % interval != 0 )) && continue

                set +e
                local poll_response poll_rc
                poll_response=$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
                    -d "$(jq -nc --arg dc "$device_code" '{device_code:$dc}')" \
                    "$SLIME_ID_API/device/poll" 2>/dev/null)
                poll_rc=$?
                set -e
                (( poll_rc != 0 )) && continue

                local status
                status=$(jq -r '.status // "pending"' <<<"$poll_response" 2>/dev/null)
                if [[ "$status" == "approved" ]]; then
                    outcome="approved"; approved_response="$poll_response"; break
                elif [[ "$status" == "expired" ]]; then
                    outcome="expired"; break
                fi
            done

            case "$outcome" in
                approved)
                    jq -nc --arg token "$(jq -r '.session_token' <<<"$approved_response")" \
                        --arg email "$(jq -r '.user.email' <<<"$approved_response")" \
                        --arg name "$(jq -r '.user.name' <<<"$approved_response")" \
                        '{token:$token, email:$email, name:$name}' > "$SLIME_ID_SESSION_FILE" \
                        || log "Failed to write slime-id-session"
                    return 0
                    ;;
                cancelled)
                    return 0
                    ;;
                *)
                    # 'expired' and 'timeout' get the same user-facing
                    # message -- both just mean "too slow, try again."
                    emit_state slimeIdError '{"message":"That sign-in link expired.","detail":"device code expired before approval"}'
                    ;;
            esac
        fi

        # Reached only via a fallthrough from either phase above emitting
        # slimeIdError -- same shape as pairError's own retry/back loop.
        while true; do
            local line ev_type
            line=$(read_event) || return 0
            ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
            case "$ev_type" in
                retry) phase="starting"; continue 2 ;;
                back|forceBack) return 0 ;;
                *)
                    try_handle_power_event "$ev_type" || :
                    try_handle_crash_report "$ev_type" "$line" || :
                    ;;
            esac
        done
    done
}

# Called directly from coordinator.sh's outer dispatch on a one-shot
# 'slimeIdLogout' event -- no loop-owning function needed, same shape as
# the crashConsent case handling itself inline. Best-effort: a failed
# revoke call still clears the local file (the device stops SHOWING as
# signed in either way; the worst case is a session token that just sits
# unused server-side until its normal 30-day expiry, not a security hole
# -- same non-fatal posture as every other outbound call in this codebase
# that isn't the one thing the user is waiting on).
slime_id_logout() {
    local token
    token=$(jq -r '.token // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null)

    if [[ -n "$token" ]]; then
        set +e
        curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg t "$token" '{session_token:$t}')" \
            "$SLIME_ID_API/device/logout" >/dev/null 2>&1
        set -e
    fi

    : > "$SLIME_ID_SESSION_FILE" || log "Failed to clear slime-id-session"
}
