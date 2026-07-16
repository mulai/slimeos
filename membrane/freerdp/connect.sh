#!/usr/bin/env bash
# Slime OS — FreeRDP connection function library
#
# This file is no longer a standalone script — it is `source`d by
# membrane/session/coordinator.sh, which defines the surrounding event loop,
# `log`/`emit_state`/`read_event` helpers, and loads hw-freerdp-flags/config
# into the variables this file's do_connect() function reads
# (SLIMEOS_FREERDP_EXTRA_FLAGS, RES_FLAGS, RDP_NETWORK, RECONNECT_DELAY,
# MIN_SESSION_SECONDS, FREERDP_LOG_FILE, BRAINS_FILE, CRED_DIR).
#
# do_connect() replaces the old top-level script + its `exec "$0" ...` /
# `exec brain-select.sh` self-replacement chain: a persistent coordinator
# can never exec-replace itself (its stdin/stdout pipe to slimeos-bridge is
# the WebSocket session's lifeline), so every one of those old `exec` calls
# is now a plain `return 0` back into coordinator.sh's dispatch loop, which
# always shows the Brain picker next — exactly what every one of those old
# `exec brain-select.sh` calls did.

# First ALSA card that is both USB and capture-capable. USB microphones
# enumerate as their own ALSA card, but ALSA's *default* capture device
# stays pointed at the onboard input (typically an empty rear mic jack) --
# so without this, a plugged-in USB mic reaches the Brain as pure silence
# while Windows shows a perfectly healthy "Remote Audio" recording device.
# /proc/asound needs no alsa-utils and is authoritative; "pcm*c" nodes are
# capture streams (a USB DAC/speaker without a mic exposes only pcm*p).
usb_capture_card() {
    local idx name
    while read -r idx name; do
        if compgen -G "/proc/asound/card${idx}/pcm*c" >/dev/null; then
            printf '%s' "$name"
            return 0
        fi
    done < <(awk '/USB-Audio/ {gsub(/\[/, "", $2); print $1, $2}' /proc/asound/cards 2>/dev/null)
    return 1
}

# Wake a managed cloud Brain before attempting RDP. The hub's power
# service (brain/power, http://10.10.0.1:7677 — plain HTTP over the
# tunnel, so Membrane clock drift can't break a TLS handshake here)
# auto-deallocates idle cloud VMs to stop them billing 24/7; this is the
# other half. Zero device config: unmanaged hosts answer {managed:false}
# instantly, and hubs without the service refuse the connection outright
# (an RST, not the 3s timeout) — both fall through to exactly the
# behavior that existed before this feature.
#
# Polls POST /wake (idempotent), NOT a read-only status endpoint: if the
# first call lands while the VM is still deallocating (user reconnecting
# right after the idle watchdog fired), only a later /wake can issue the
# start once deallocation completes.
#
# Returns 0 → proceed to the xfreerdp attempt (including on wake failure/
# timeout — xfreerdp then fails fast into the existing error screen);
# 1 → user backed out (cancel/back). Note an issued ARM start can't be
# cancelled: the VM boots anyway and the hub's idle watchdog reaps it.
wake_brain() {
    local vm_host="$1" vm_port="$2" brain_name="$3"
    # Overridable via /etc/slimeos/config for hubs on a different subnet
    # (and for the local test harness).
    local power_url="${SLIMEOS_POWER_URL:-http://10.10.0.1:7677}"
    local body response managed state rc line ev_type
    body=$(jq -nc --arg h "$vm_host" '{host:$h}')

    set +e
    response=$(curl -fsS -m 3 -X POST -H 'Content-Type: application/json' \
        -d "$body" "${power_url}/wake" 2>/dev/null)
    rc=$?
    set -e
    (( rc != 0 )) && return 0
    managed=$(jq -r '.managed // false' <<<"$response" 2>/dev/null || echo false)
    [[ "$managed" != "true" ]] && return 0
    state=$(jq -r '.state // "unknown"' <<<"$response" 2>/dev/null || echo unknown)
    [[ "$state" == "running" ]] && return 0
    log "Brain ${brain_name} is ${state} — waking it"

    emit_state connecting "$(jq -nc --arg n "$brain_name" \
        '{brainName:$n,stage:"Waking up your Brain… (about a minute)"}')"

    local waited=0
    while (( waited < 300 )); do
        # 1s event-responsive slices, same shape as the reconnect-wait
        # loop below: cancel/back/power events must work mid-wake.
        if read -t 1 -r line <&0; then
            ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
            case "$ev_type" in
                cancelConnect|back) return 1 ;;
                *) try_handle_power_event "$ev_type" || : ;;
            esac
        else
            rc=$?
            if (( rc <= 128 )); then
                log "stdin closed during wake wait — exiting"
                exit 0
            fi
        fi
        waited=$((waited + 1))
        (( waited % 5 != 0 )) && continue

        set +e
        response=$(curl -fsS -m 3 -X POST -H 'Content-Type: application/json' \
            -d "$body" "${power_url}/wake" 2>/dev/null)
        rc=$?
        set -e
        (( rc != 0 )) && continue      # transient hub blip — keep waiting
        state=$(jq -r '.state // "unknown"' <<<"$response" 2>/dev/null || echo unknown)
        [[ "$state" == "failed" ]] && break
        [[ "$state" != "running" ]] && continue

        # ARM "running" ≠ RDP-ready: Windows still boots for a while.
        # Probe the actual port; `timeout 2` caps the filtered/black-hole
        # hang bash's /dev/tcp is otherwise capable of (refusal while
        # booting returns instantly).
        log "Brain ${brain_name} is up — waiting for the desktop to listen"
        emit_state connecting "$(jq -nc --arg n "$brain_name" \
            '{brainName:$n,stage:"Brain is up — starting the desktop…"}')"
        while (( waited < 300 )); do
            if timeout 2 bash -c "exec 3<>/dev/tcp/${vm_host}/${vm_port}" 2>/dev/null; then
                return 0
            fi
            if read -t 1 -r line <&0; then
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    cancelConnect|back) return 1 ;;
                    *) try_handle_power_event "$ev_type" || : ;;
                esac
            fi
            waited=$((waited + 3))
        done
        break
    done
    return 0
}

do_connect() {
    local brain_id="$1"
    local brain_json
    brain_json=$(jq -c --arg id "$brain_id" '.[] | select(.id == $id)' "$BRAINS_FILE")
    if [[ -z "$brain_json" ]]; then
        log "ERROR: brain id $brain_id not found"
        return 0
    fi

    local vm_host vm_port slime_username brain_name
    vm_host=$(jq -r '.host' <<<"$brain_json")
    vm_port=$(jq -r '.port' <<<"$brain_json")
    slime_username=$(jq -r '.username' <<<"$brain_json")
    brain_name=$(jq -r '.name' <<<"$brain_json")

    local cred_file="$CRED_DIR/${brain_id}.cred"
    # Same per-Brain key derivation as before: machine-bound, brain-bound,
    # so a stolen brains.json + brains/ directory is useless off-device.
    local cred_pass; cred_pass="$(cat /etc/machine-id)-${brain_id}"
    local rdp_pass attempt=1

    # Two phases, dispatched by `phase`:
    #   "credentials" — only entered when username or password is still
    #                   needed; blocks on a `credentials` event.
    #   "connect"     — the xfreerdp attempt loop; also owns reconnect-on-
    #                   drop and retry-on-error internally.
    # `reenterPassword` (from the error screen) is the only thing that
    # needs to jump back out to "credentials" from inside the connect
    # phase, hence the `continue 3` a few screens down: counting from the
    # innermost currently-running loop, 1 = the error-wait loop itself,
    # 2 = the connect-attempt loop, 3 = this outer phase-dispatch loop.
    local phase="credentials"
    while true; do
        if [[ "$phase" == "credentials" ]]; then
            local need_username=false
            [[ -z "$slime_username" ]] && need_username=true

            if $need_username || [[ ! -f "$cred_file" ]]; then
                emit_state credentials "$(jq -nc --arg n "$brain_name" --argjson nu "$need_username" \
                    '{brainName:$n,needUsername:$nu}')"
                local got_creds=false
                while ! $got_creds; do
                    local line ev_type
                    line=$(read_event) || return 0
                    ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                    case "$ev_type" in
                        credentials)
                            if $need_username; then
                                local new_username
                                new_username=$(jq -r '.username // empty' <<<"$line")
                                [[ -n "$new_username" ]] || continue
                                slime_username="$new_username"
                                # Write-through, not `mv`: replacing a file via
                                # rename() needs write permission on
                                # /etc/slimeos itself, which is (and should
                                # stay) root-owned — we only own brains.json.
                                local tmp; tmp=$(mktemp)
                                jq --arg id "$brain_id" --arg u "$slime_username" \
                                    'map(if .id == $id then .username = $u else . end)' \
                                    "$BRAINS_FILE" > "$tmp" && cat "$tmp" > "$BRAINS_FILE"
                                rm -f "$tmp"
                            fi
                            local pw; pw=$(jq -r '.password // empty' <<<"$line")
                            echo "$pw" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$cred_pass" > "$cred_file"
                            chmod 600 "$cred_file"
                            got_creds=true
                            ;;
                        back) return 0 ;;
                        *) try_handle_power_event "$ev_type" || : ;; # ignore anything else while waiting for credentials
                    esac
                done
            fi

            rdp_pass=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$cred_pass" < "$cred_file" 2>/dev/null || true)
            if [[ -z "$rdp_pass" ]]; then
                log "ERROR: Failed to decrypt stored credential. Re-prompting."
                rm -f "$cred_file"
                continue # phase stays "credentials"; cred_file is gone so it re-prompts
            fi

            phase="connect"
            continue
        fi

        # ── phase == "connect" ───────────────────────────────────────────────
        while true; do
            emit_state connecting "$(jq -nc --arg n "$brain_name" \
                '{brainName:$n,stage:"Waking up your Brain…"}')"

            # Wake-on-connect for managed cloud Brains (no-op for everything
            # else — see wake_brain above). Placed before log_offset/SECONDS
            # so wake time never counts toward MIN_SESSION_SECONDS. Runs on
            # every attempt-loop iteration: error-screen retries and
            # post-drop reconnects wake the VM too (a drop *because* Azure
            # rebooted the VM heals itself here).
            if ! wake_brain "$vm_host" "$vm_port" "$brain_name"; then
                log "Connect cancelled during Brain wake"
                return 0
            fi

            log "Connecting to ${brain_name} (${vm_host}:${vm_port}) as ${slime_username}"
            # First-ever connect on a fresh install: nothing creates this file
            # ahead of time (it's only ever opened via the xfreerdp3 `>>`
            # redirect a few lines down), so `wc -c` on a missing file would
            # otherwise kill the whole coordinator under `set -e`.
            local log_offset; log_offset=$(wc -c < "$FREERDP_LOG_FILE" 2>/dev/null || echo 0)
            SECONDS=0

            # Security flags (zero-trust stack):
            #   /sec:rdp:off — disable only legacy plain-RDP security and
            #                  negotiate the rest: Windows Brains require
            #                  NLA, xrdp Brains only offer TLS (no
            #                  CredSSP/NLA support at all) — forcing either
            #                  one breaks the other.
            #   /cert:tofu   — trust on first use, then pin.
            # No /tls:seclevel: FreeRDP 3.15's /tls sub-option parser
            # rejects even its own documented values (non-fatal ERROR,
            # option ignored) — the server side enforces the TLS floor.
            #
            # xfreerdp3 (freerdp3-x11) is an X11 client and needs $DISPLAY,
            # but this process tree (coordinator.sh, under slimeos-bridge.
            # service) is not a descendant of cage/cog (slimeos-session.
            # service) — two separate systemd units — so it never inherits
            # the DISPLAY cage injects into cog's own environment. Both
            # units share XDG_RUNTIME_DIR, and Xwayland's X11 socket lives
            # in the filesystem regardless of process ancestry, so discover
            # it directly rather than relying on inheritance. Re-checked
            # every attempt (cheap) in case cage restarts mid-retry-loop
            # and Xwayland comes back on a different display number.
            local x11_socket
            x11_socket=$(ls /tmp/.X11-unix/ 2>/dev/null | head -1)
            export DISPLAY="${x11_socket:+:${x11_socket#X}}"
            export DISPLAY="${DISPLAY:-:0}"

            # Prefer a USB microphone when one is present (see
            # usb_capture_card above). Re-checked every attempt like the
            # DISPLAY discovery, so a mic plugged in mid-retry-loop is
            # picked up without restarting anything. Card NAME, not
            # index — replug/boot reordering can't silently break the
            # pick; plughw so FreeRDP's requested sample format needn't
            # match the mic's native one. Confirmed live: USB PnP mic →
            # Azure Windows Brain, 2026-07-16.
            local mic_flag="/microphone:sys:alsa" usb_mic
            if usb_mic=$(usb_capture_card); then
                mic_flag="/microphone:sys:alsa,dev:plughw:CARD=${usb_mic}"
                log "USB microphone detected (ALSA card '${usb_mic}') — redirecting it"
            fi

            # Peripheral redirection (speaker/mic/USB storage):
            #   /sound, /microphone — explicit `sys:alsa` because the
            #     Membrane has no PulseAudio/PipeWire daemon installed;
            #     ALSA talks to the kernel driver directly (session user is
            #     in the `audio` group). Was previously /audio-mode:2
            #     ("do not play"), which disabled sound outright.
            #   /drive:usb,... — shares whatever udiskie (slimeos-automount.
            #     service) has auto-mounted under /media/<user> as one
            #     dynamic network drive in the Brain; picks up drives
            #     plugged in mid-session without a reconnect. Encrypted
            #     (LUKS) volumes aren't handled — no unlock-prompt UI exists
            #     on this kiosk yet.
            set +e
            xfreerdp3 \
                /v:"${vm_host}:${vm_port}" \
                /u:"${slime_username}" \
                /p:"${rdp_pass}" \
                /sec:rdp:off \
                /cert:tofu \
                /network:"${RDP_NETWORK:-auto}" \
                ${RES_FLAGS} \
                /dynamic-resolution \
                /sound:sys:alsa \
                ${mic_flag} \
                /drive:usb,"/media/$(id -un)" \
                /log-level:WARN \
                ${SLIMEOS_FREERDP_EXTRA_FLAGS} >> "$FREERDP_LOG_FILE" 2>&1 &
            local xpid=$! cancelled=false

            while kill -0 "$xpid" 2>/dev/null; do
                if read -t 1 -r line <&0; then
                    local ev_type
                    ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                    if [[ "$ev_type" == "cancelConnect" ]]; then
                        kill "$xpid" 2>/dev/null || true
                        cancelled=true
                        break
                    else
                        # A successful systemctl call here means the machine is
                        # about to power off/reboot regardless -- no need to
                        # kill xfreerdp ourselves, the OS shutdown handles that.
                        try_handle_power_event "$ev_type" || :
                    fi
                else
                    local rc=$?
                    if (( rc <= 128 )); then
                        # stdin closed (EOF): the bridge itself is going
                        # away, most likely a full system shutdown. Leave
                        # xfreerdp running rather than killing an active
                        # remote session out from under the user —
                        # systemd will respawn the bridge and a fresh
                        # coordinator, which just won't know about this
                        # session until it ends on its own.
                        log "stdin closed during an active connection — detaching, letting xfreerdp continue"
                        exit 0
                    fi
                    # rc > 128: plain read timeout — loop back to the kill -0 check.
                fi
            done

            wait "$xpid" 2>/dev/null; local exit_code=$?
            set -e
            local runtime=$SECONDS

            if $cancelled; then
                log "Connect cancelled by user"
                return 0
            fi
            log "FreeRDP exited with code $exit_code after ${runtime}s"

            # FreeRDP3 returns the raw ERRINFO_* wire code as its exit
            # status for a graceful, protocol-level session end (as
            # opposed to the 128+ range used for real connection
            # failures) -- 0 alone missed the common case of a user
            # logging off *from inside* the remote desktop, which
            # surfaced as a bogus "Can't reach this Brain" error instead
            # of a silent return to the picker. Per FreeRDP's error.h:
            #   0  ERRINFO_SUCCESS
            #   1  ERRINFO_RPC_INITIATED_DISCONNECT
            #   2  ERRINFO_RPC_INITIATED_LOGOFF
            #   11 ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER
            #   12 ERRINFO_LOGOFF_BY_USER
            # Deliberately NOT included: idle/logon timeout and
            # disconnected-by-other-connection -- those are worth
            # surfacing to the user, not swallowing silently.
            case "$exit_code" in
                0|1|2|11|12)
                    log "Clean disconnect (exit code $exit_code) — returning to Brain picker"
                    return 0
                    ;;
            esac

            # A session that survived at least this long before dying is
            # treated as a network drop (auto-reconnect); anything shorter
            # is a connect/auth failure and gets an error screen instead.
            # Blind retries on fast failures are dangerous: repeated failed
            # logons can lock a Windows account within a minute.
            if (( runtime >= MIN_SESSION_SECONDS )) && [[ "${RECONNECT_DELAY:-5}" -ne 0 ]]; then
                attempt=$((attempt + 1))
                emit_state reconnecting "$(jq -nc --arg n "$brain_name" --argjson a "$attempt" \
                    '{brainName:$n,attempt:$a}')"
                log "Session dropped — reconnecting in ${RECONNECT_DELAY}s (attempt $attempt)..."
                local waited=0 backed_out=false
                while (( waited < ${RECONNECT_DELAY:-5} )); do
                    if read -t 1 -r line <&0; then
                        local ev_type
                        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                        if [[ "$ev_type" == "back" ]]; then
                            backed_out=true
                            break
                        else
                            try_handle_power_event "$ev_type" || :
                        fi
                    else
                        local rc=$?
                        if (( rc <= 128 )); then
                            log "stdin closed during reconnect wait — exiting"
                            exit 0
                        fi
                    fi
                    waited=$((waited + 1))
                done
                $backed_out && return 0
                continue
            fi

            # Fast failure: map the raw FreeRDP3 error to a human-readable
            # message for the UI; keep the raw code as `detail` for the
            # collapsed "technical details" line. Only grep the log this
            # attempt appended, not older attempts' errors.
            local err_hint message detail
            err_hint=$(tail -c +$((log_offset + 1)) "$FREERDP_LOG_FILE" \
                | grep -o 'ERRCONNECT_[A-Z_]*' | tail -1 || true)
            case "$err_hint" in
                ERRCONNECT_AUTHENTICATION_FAILED|ERRCONNECT_LOGON_FAILURE)
                    message="That password didn't work." ;;
                ERRCONNECT_ACCOUNT_LOCKED_OUT)
                    message="This account is temporarily locked. Wait about 10 minutes." ;;
                *NEGO*|*SECURITY*)
                    message="Couldn't establish a secure connection." ;;
                *TIMEOUT*|*TRANSPORT*|"")
                    message="Can't reach this Brain. Check that it's running." ;;
                *)
                    message="Connection failed." ;;
            esac
            detail="${err_hint:-exit code $exit_code}"
            emit_state error "$(jq -nc --arg n "$brain_name" --arg m "$message" --arg d "$detail" \
                '{brainName:$n,message:$m,detail:$d}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    retry) continue 2 ;;
                    reenterPassword)
                        rm -f "$cred_file"
                        phase="credentials"
                        continue 3
                        ;;
                    back) return 0 ;;
                    *) try_handle_power_event "$ev_type" || : ;;
                esac
            done
        done
    done
}
