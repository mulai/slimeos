#!/usr/bin/env bash
# Slime OS — Membrane lock screen
#
# `source`d by membrane/session/coordinator.sh (after slime-id.sh, whose
# SLIME_ID_API/SLIME_ID_SESSION_FILE it uses), same shape as the other do_*
# screens: relies on coordinator.sh's own log()/emit_state()/read_event()
# helpers. Design + decisions: docs/membrane-lock-screen-proposal.md.
#
# Opt-in (Settings › Security, only offered while signed in to Slime ID).
# When on, the device locks at every coordinator start (boot), after every
# Brain session ends, and on "Lock now". do_lock_screen() is a blocking loop
# that consumes every event itself until unlocked -- so while it runs,
# nothing else (picker, Settings, connect) is reachable, except Wi-Fi setup
# and power, which it handles directly.
#
# Two ways to unlock:
#   * QR -- /api/device/unlock-start creates a code only this device's own
#     Slime ID can approve; polling /api/device/poll until approved. Never
#     mints a session (the device already has one).
#   * Recovery PIN -- the 8-digit PIN shown once at install, verified as
#     slime-recovery's password by the system itself (su/PAM), never against
#     a stored copy. Rate-limited, with the counter on disk so a reboot
#     doesn't reset it. The PIN is never logged or stored.
#
# If the device's Slime ID session turns out to be revoked/expired
# (unlock-start answers signed_out), the local session file is cleared and
# QR unlock is disabled -- PIN only. A *new* sign-in can never unlock the
# device: that would let any Slime ID holder unlock anyone's Membrane.

# $CONFIG_DIR is root-owned (only install-time-seeded files in it are ours
# to write), so the lock's own state lives in the session user's home.
LOCK_STATE_DIR="${HOME:-/home/$(id -un)}/.local/state/slimeos"
LOCK_ENABLED_FILE="$LOCK_STATE_DIR/lock-enabled"
LOCK_PIN_ATTEMPTS_FILE="$LOCK_STATE_DIR/lock-pin-attempts"
mkdir -p "$LOCK_STATE_DIR" 2>/dev/null && chmod 700 "$LOCK_STATE_DIR" 2>/dev/null || :

LOCK_PIN_FREE_ATTEMPTS=5
LOCK_PIN_MAX_WAIT=3600

lock_is_enabled() {
    [[ "$(cat "$LOCK_ENABLED_FILE" 2>/dev/null)" == "on" ]]
}

lock_set_enabled() {
    if [[ "$1" == "true" ]]; then
        echo on > "$LOCK_ENABLED_FILE"
    else
        rm -f "$LOCK_ENABLED_FILE"
    fi
}

slime_id_token() {
    jq -r '.token // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null || true
}

# Device label for /device ("Unlock <label>"); also sent on sign-in.
membrane_label() {
    local h; h=$(hostname 2>/dev/null || echo "")
    echo "${h:-Membrane}"
}

# Prints "<failures> <next_allowed_epoch>" (defaults "0 0").
lock_pin_attempts_read() {
    local f="" n=""
    # No file yet is the normal case (no failures) -- guard it, since a bare
    # `< missing` fails before read runs and leaves both unset.
    if [[ -f "$LOCK_PIN_ATTEMPTS_FILE" ]]; then
        read -r f n < "$LOCK_PIN_ATTEMPTS_FILE" || true
    fi
    [[ "$f" =~ ^[0-9]+$ ]] || f=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$f $n"
}

# Returns 0 = correct, 1 = wrong, 2 = rate-limited (nothing checked).
# LOCK_PIN_RETRY_AT is set to the epoch the next try is allowed (0 = now).
LOCK_PIN_RETRY_AT=0
lock_check_pin() {
    local pin="$1" failures next now
    read -r failures next <<<"$(lock_pin_attempts_read)"
    now=$(date +%s)
    if (( now < next )); then
        LOCK_PIN_RETRY_AT=$next
        return 2
    fi

    # Only digits reach su; anything else is just a wrong PIN.
    local ok=false
    if [[ "$pin" =~ ^[0-9]{4,16}$ ]] && \
        printf '%s\n' "$pin" | timeout 15 su -s /bin/sh -c true slime-recovery >/dev/null 2>&1; then
        ok=true
    fi

    if $ok; then
        rm -f "$LOCK_PIN_ATTEMPTS_FILE"
        LOCK_PIN_RETRY_AT=0
        return 0
    fi

    failures=$((failures + 1))
    next=0
    if (( failures >= LOCK_PIN_FREE_ATTEMPTS )); then
        # 1 min, doubling per further failure, capped. The shift is capped
        # too: bash masks shift counts, so a huge one would wrap back small.
        local shift=$(( failures - LOCK_PIN_FREE_ATTEMPTS ))
        (( shift > 6 )) && shift=6
        local wait=$(( 60 << shift ))
        (( wait > LOCK_PIN_MAX_WAIT )) && wait=$LOCK_PIN_MAX_WAIT
        next=$(( $(date +%s) + wait ))
    fi
    echo "$failures $next" > "$LOCK_PIN_ATTEMPTS_FILE" || log "Failed to write lock-pin-attempts"
    LOCK_PIN_RETRY_AT=$next
    log "Lock screen: wrong recovery PIN (failure $failures)"
    return 1
}

# Blocks until the device is unlocked (returns 0). Returns immediately if
# the lock isn't enabled.
do_lock_screen() {
    lock_is_enabled || return 0
    log "Lock screen: locked"

    local device_code="" user_code="" verification_uri="" qr_data_url=""
    local interval=4 code_expires=0 next_code_try=0
    local qr_state="loading" pin_error="" signed_out=false

    # Fetches a fresh unlock code; sets qr_state to ready/offline/signed_out.
    lock_fetch_code() {
        local token; token=$(slime_id_token)
        if [[ -z "$token" ]]; then
            qr_state="signed_out"; return
        fi
        set +e
        local response http
        response=$(curl -sS -m 10 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg t "$token" --arg l "$(membrane_label)" '{session_token:$t, label:$l}')" \
            "$SLIME_ID_API/device/unlock-start" 2>/dev/null)
        set -e
        http=${response##*$'\n'}
        response=${response%$'\n'*}
        if [[ "$http" == "401" ]] && [[ "$(jq -r '.error // empty' <<<"$response" 2>/dev/null)" == "signed_out" ]]; then
            log "Lock screen: Slime ID session no longer valid — clearing it, PIN unlock only"
            : > "$SLIME_ID_SESSION_FILE" || log "Failed to clear slime-id-session"
            qr_state="signed_out"; return
        fi
        device_code=$(jq -r '.device_code // empty' <<<"$response" 2>/dev/null || true)
        user_code=$(jq -r '.user_code // empty' <<<"$response" 2>/dev/null || true)
        verification_uri=$(jq -r '.verification_uri // empty' <<<"$response" 2>/dev/null || true)
        qr_data_url=$(jq -r '.qr_data_url // empty' <<<"$response" 2>/dev/null || true)
        interval=$(jq -r '.interval // 4' <<<"$response" 2>/dev/null || echo 4)
        local expires_in; expires_in=$(jq -r '.expires_in // 900' <<<"$response" 2>/dev/null || echo 900)
        if [[ -n "$device_code" && -n "$user_code" ]]; then
            qr_state="ready"
            code_expires=$(( $(date +%s) + expires_in - 5 ))
        else
            qr_state="offline"
            next_code_try=$(( $(date +%s) + 30 ))
        fi
    }

    lock_emit() {
        emit_state lockScreen "$(jq -nc --arg qs "$qr_state" --arg u "$user_code" --arg v "$verification_uri" \
            --arg q "$qr_data_url" --arg pe "$pin_error" --argjson ra "$LOCK_PIN_RETRY_AT" \
            --arg label "$(membrane_label)" \
            '{qrState:$qs, userCode:$u, verificationUri:$v, qrDataUrl:$q,
              pinError:(if $pe == "" then null else $pe end), pinRetryAt:$ra, label:$label}')"
    }

    local failures; read -r failures LOCK_PIN_RETRY_AT <<<"$(lock_pin_attempts_read)"
    # At boot this runs before the picker ever sent the status strip.
    send_status
    lock_fetch_code
    lock_emit

    local tick=0
    while true; do
        local line="" ev_type=""
        if read -t 1 -r line <&0; then
            ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
            case "$ev_type" in
                unlockPin)
                    local pin rc
                    pin=$(jq -r '.pin // empty' <<<"$line" 2>/dev/null || true)
                    set +e; lock_check_pin "$pin"; rc=$?; set -e
                    pin=""
                    if (( rc == 0 )); then
                        log "Lock screen: unlocked with recovery PIN"
                        return 0
                    elif (( rc == 2 )); then
                        pin_error="Too many wrong tries. Wait before trying again."
                    else
                        pin_error="That PIN isn't right."
                    fi
                    lock_emit
                    ;;
                lockNewCode)
                    lock_fetch_code; pin_error=""; lock_emit
                    ;;
                lockWifi)
                    do_network_setup boot
                    lock_fetch_code; lock_emit
                    ;;
                _clientConnected)
                    send_status
                    lock_emit
                    ;;
                *)
                    try_handle_power_event "$ev_type" || :
                    try_handle_crash_report "$ev_type" "$line" || :
                    ;;
            esac
            continue
        else
            local rc=$?
            if (( rc <= 128 )); then
                log "stdin closed on lock screen — exiting"
                exit 0
            fi
        fi

        tick=$((tick + 1))
        local now; now=$(date +%s)
        case "$qr_state" in
            ready)
                if (( now >= code_expires )); then
                    lock_fetch_code; lock_emit; continue
                fi
                (( tick % interval == 0 )) || continue
                set +e
                local poll_response
                poll_response=$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
                    -d "$(jq -nc --arg dc "$device_code" '{device_code:$dc}')" \
                    "$SLIME_ID_API/device/poll" 2>/dev/null)
                set -e
                case "$(jq -r '.status // "pending"' <<<"$poll_response" 2>/dev/null)" in
                    approved)
                        log "Lock screen: unlocked via Slime ID approval"
                        return 0
                        ;;
                    expired)
                        lock_fetch_code; lock_emit
                        ;;
                esac
                ;;
            offline|loading)
                if (( now >= next_code_try )); then
                    lock_fetch_code
                    [[ "$qr_state" == "ready" || "$qr_state" == "signed_out" ]] && lock_emit
                fi
                ;;
        esac
    done
}

# Settings › Security tab. Same shape as support.sh's do_support().
do_security() {
    local mode="$1" error=""
    while true; do
        local enabled="false" signed_in="false" email=""
        lock_is_enabled && enabled="true"
        if [[ -n "$(slime_id_token)" ]]; then
            signed_in="true"
            email=$(jq -r '.email // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null || true)
        fi
        emit_state securitySettings "$(jq -nc --arg mode "$mode" --argjson enabled "$enabled" \
            --argjson signedIn "$signed_in" --arg email "$email" --arg error "$error" \
            '{mode:$mode, enabled:$enabled, signedIn:$signedIn, email:(if $email == "" then null else $email end),
              error:(if $error == "" then null else $error end)}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            lockToggle)
                local want; want=$(jq -r '.enabled // false' <<<"$line")
                if [[ "$want" == "true" && "$signed_in" != "true" ]]; then
                    error="Sign in with Slime ID first. The lock screen needs it to unlock by QR code."
                elif ! lock_set_enabled "$want"; then
                    error="Couldn't change the lock setting right now."
                else
                    log "Lock screen: turned $([[ "$want" == "true" ]] && echo on || echo off)"
                fi
                ;;
            lockNow)
                if lock_is_enabled; then
                    SETTINGS_LOCK_NOW=true
                    return 0
                fi
                ;;
            settingsTab)
                [[ "$mode" == "settings" ]] || continue
                SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                [[ -n "$SETTINGS_NEXT_TAB" ]] && return 0
                ;;
            back|forceBack) return 0 ;;
            *)
                try_handle_power_event "$ev_type" || :
                try_handle_crash_report "$ev_type" "$line" || :
                ;;
        esac
    done
}
