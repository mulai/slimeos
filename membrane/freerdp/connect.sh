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

# True if $1 (an ALSA card index) is the audio interface of a device that
# ALSO exposes a video4linux capture interface -- i.e. a webcam's built-in
# mic, not a dedicated USB microphone. A webcam's audio and video are
# separate USB interfaces on the SAME physical device, so they share the
# same parent directory in sysfs (e.g. audio at .../usb2/2-5/2-5:1.2, video
# at .../usb2/2-5/2-5:1.0 -- same "2-5" parent, different ":I.N" interface
# suffix). Confirmed live 2026-08-14 on the AMD box: the Logitech C920's
# mic (card 2) enumerates ahead of the dedicated USB mic dongle (card 3) in
# /proc/asound/cards, so usb_capture_card's old first-match logic had been
# silently redirecting the webcam's mic instead of the dongle every single
# session that day -- worse quality, and not what Tommy thought he was
# testing when chasing an unrelated audio-quality report.
is_webcam_audio_card() {
    local card="$1" card_dev card_parent video_dev video_parent
    card_dev=$(readlink -f "/sys/class/sound/card${card}/device" 2>/dev/null) || return 1
    card_parent=$(dirname "$card_dev")
    for video_dev in /sys/class/video4linux/video*/device; do
        [[ -e "$video_dev" ]] || continue
        video_parent=$(dirname "$(readlink -f "$video_dev")")
        [[ "$video_parent" == "$card_parent" ]] && return 0
    done
    return 1
}

# First ALSA card that is both USB and capture-capable. USB microphones
# enumerate as their own ALSA card, but ALSA's *default* capture device
# stays pointed at the onboard input (typically an empty rear mic jack) --
# so without this, a plugged-in USB mic reaches the Brain as pure silence
# while Windows shows a perfectly healthy "Remote Audio" recording device.
# /proc/asound needs no alsa-utils and is authoritative; "pcm*c" nodes are
# capture streams (a USB DAC/speaker without a mic exposes only pcm*p).
# Skips a webcam's mic (see is_webcam_audio_card above) in favor of a
# dedicated mic when both are present, but still falls back to a webcam's
# mic if it's the only USB capture device around -- better than silence on
# a webcam-only setup.
usb_capture_card() {
    local idx name fallback=""
    while read -r idx name; do
        if compgen -G "/proc/asound/card${idx}/pcm*c" >/dev/null; then
            if is_webcam_audio_card "$idx"; then
                [[ -z "$fallback" ]] && fallback="$name"
                continue
            fi
            printf '%s' "$name"
            return 0
        fi
    done < <(awk '/USB-Audio/ {gsub(/\[/, "", $2); print $1, $2}' /proc/asound/cards 2>/dev/null)
    if [[ -n "$fallback" ]]; then
        printf '%s' "$fallback"
        return 0
    fi
    return 1
}

# ALSA's own "default" PCM resolves to card 0 with no check that it
# actually supports playback -- on hardware where a capture-only device
# (USB mic dongle, webcam mic) happens to enumerate ahead of the real
# speakers, xfreerdp3's bare `/sound:sys:alsa` then fails outright
# (`rdpsnd_alsa_open: snd_pcm_open failed`), silently killing the speaker
# while the mic -- which explicitly targets its own card, see
# usb_capture_card above -- keeps working. Confirmed live on the AMD box
# 2026-08-10: /proc/asound/cards had a USB mic dongle at card 0
# (capture-only, no pcm*p node) ahead of the onboard ALC887 at card 2.
# Mirrors usb_capture_card's approach: walk cards in index order, return
# the first one with a pcm*p node (i.e. actually has a playback substream).
default_playback_card() {
    local idx name
    while read -r idx name; do
        if compgen -G "/proc/asound/card${idx}/pcm*p" >/dev/null; then
            printf '%s' "$name"
            return 0
        fi
    done < <(awk '{gsub(/\[/, "", $2); print $1, $2}' /proc/asound/cards 2>/dev/null)
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
                cancelConnect|back|forceBack) return 1 ;;
                *)
                    try_handle_power_event "$ev_type" || :
                    try_handle_crash_report "$ev_type" "$line" || :
                    ;;
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
                    cancelConnect|back|forceBack) return 1 ;;
                    *)
                        try_handle_power_event "$ev_type" || :
                        try_handle_crash_report "$ev_type" "$line" || :
                        ;;
                esac
            fi
            waited=$((waited + 3))
        done
        break
    done
    return 0
}

# Best-effort POST to /api/device/brain-credential -- fetched fresh
# immediately before every connect attempt to a kind='paid' brain, never
# cached in $CRED_DIR's .cred file mechanism (every connect gets a live
# fetch; no cache/invalidation problem to solve). Echoes
# {"ok":true,"username":...,"password":...} on success, {"ok":false} on ANY
# failure (offline, not signed into Slime ID, brain has no stored
# credential yet, server error) -- callers treat every ok:false identically:
# fall back to the existing manual-entry+local-cache flow. Mirrors
# coordinator.sh's fetch_remote_brains() exactly (same
# SLIME_ID_API/SLIME_ID_SESSION_FILE globals, same non-fatal curl posture --
# both are defined in slime-id.sh, sourced before this is ever called).
fetch_brain_credential() {
    local brain_id="$1" token
    token=$(jq -r '.token // empty' "$SLIME_ID_SESSION_FILE" 2>/dev/null)
    if [[ -z "$token" ]]; then
        echo '{"ok":false}'
        return
    fi

    set +e
    local response
    response=$(curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "$token" --arg id "$brain_id" '{session_token:$t, brainId:$id}')" \
        "$SLIME_ID_API/device/brain-credential" 2>/dev/null)
    set -e

    if jq -e '.ok == true and (.password // "") != ""' <<<"$response" >/dev/null 2>&1; then
        echo "$response"
    else
        echo '{"ok":false}'
    fi
}

do_connect() {
    local brain_id="$1"
    local brain_json
    brain_json=$(jq -c --arg id "$brain_id" '.[] | select(.id == $id)' "$BRAINS_FILE")
    if [[ -z "$brain_json" ]]; then
        log "ERROR: brain id $brain_id not found"
        return 0
    fi

    local vm_host vm_port slime_username brain_name brain_kind
    vm_host=$(jq -r '.host' <<<"$brain_json")
    vm_port=$(jq -r '.port' <<<"$brain_json")
    slime_username=$(jq -r '.username' <<<"$brain_json")
    brain_name=$(jq -r '.name' <<<"$brain_json")
    brain_kind=$(jq -r '.kind // "free"' <<<"$brain_json")

    local cred_file="$CRED_DIR/${brain_id}.cred"
    # Same per-Brain key derivation as before: machine-bound, brain-bound,
    # so a stolen brains.json + brains/ directory is useless off-device.
    local cred_pass; cred_pass="$(cat /etc/machine-id)-${brain_id}"
    local rdp_pass attempt=1
    # cred_source tracks whether rdp_pass came from a live server fetch
    # (kind='paid') or the local prompt+cache flow every other brain uses --
    # the auth-failure handling below treats the two very differently (a
    # human never typed a server-sourced password, so "Re-enter password"
    # is meaningless for it). server_auth_retried bounds the one automatic
    # re-fetch-and-retry to a single attempt per error episode.
    local cred_source="" server_auth_retried=false

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
            # kind='paid' Brains: the backend already knows the RDP
            # password (set at VM-provisioning time via the admin
            # fulfillment runbook, admin/orders/[uuid].ts) -- a signed-in
            # Slime ID user should never have to type it on the on-screen
            # keyboard. Try the live fetch FIRST, before the existing
            # need_username/cred_file prompt logic below; only fall back to
            # prompting if it fails for any reason (offline, not signed in,
            # this brain has no stored credential yet). Skipped entirely
            # for kind='free' -- their OS credentials are the customer's
            # own business, and the endpoint would 404 for them anyway
            # (server-side ownership+kind gate), but checking brain_kind
            # here avoids a pointless round-trip.
            if [[ "$brain_kind" == "paid" ]]; then
                local cred_response
                cred_response=$(fetch_brain_credential "$brain_id")
                if jq -e '.ok == true' <<<"$cred_response" >/dev/null 2>&1; then
                    rdp_pass=$(jq -r '.password' <<<"$cred_response")
                    local server_username
                    server_username=$(jq -r '.username // empty' <<<"$cred_response")
                    [[ -n "$server_username" ]] && slime_username="$server_username"
                    cred_source="server"
                    phase="connect"
                    continue
                fi
                log "No server-stored credential for paid brain $brain_id (or fetch failed) — falling back to manual entry"
            fi

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
                        back|forceBack) return 0 ;;
                        *)
                            try_handle_power_event "$ev_type" || :
                            try_handle_crash_report "$ev_type" "$line" || :
                            ;; # ignore anything else while waiting for credentials
                    esac
                done
            fi

            rdp_pass=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$cred_pass" < "$cred_file" 2>/dev/null || true)
            if [[ -z "$rdp_pass" ]]; then
                log "ERROR: Failed to decrypt stored credential. Re-prompting."
                rm -f "$cred_file"
                continue # phase stays "credentials"; cred_file is gone so it re-prompts
            fi

            cred_source="local"
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
            #   /cert:ignore — was /cert:tofu (trust on first use, then pin)
            #                  until 2026-08-03: a managed cloud Brain's
            #                  self-signed cert can regenerate across an
            #                  idle-deallocate/wake-on-connect cycle (Azure
            #                  Windows confirmed doing this live), and TOFU
            #                  treats a changed-but-still-self-signed cert
            #                  as possible tampering, prompting interactively
            #                  ("Do you trust the above certificate? Y/T/N").
            #                  xfreerdp3 here is a background child of
            #                  coordinator.sh with no terminal to answer
            #                  that on, so it hangs forever with the lock
            #                  screen still showing "Waking up your
            #                  Brain…" (no stage update exists between wake
            #                  and this xfreerdp3 call to say otherwise).
            #                  TLS identity verification is redundant here
            #                  anyway, not this project's trust boundary —
            #                  see architecture.md's "zero-trust stack":
            #                  WireGuard already authenticates and encrypts
            #                  the whole path to a known peer IP before any
            #                  of this runs.
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
            # Tried an explicit `rate:16000` override here 2026-08-10 to
            # see if it eased the tight 5ms default capture period
            # (period_size 221 @ 44100Hz, confirmed via
            # /proc/asound/cardN/pcm0c/sub0/hw_params) that was still
            # underrunning even after fixing the real CPU-hog root cause
            # (WPEWebProcess's ambientDrift animation, see index.html).
            # Made it strictly worse, not better: FreeRDP's audin ALSA
            # backend offered ZERO valid formats to the server with an
            # explicit rate set (`audin_process_open: invalid format index
            # 0 (total 0)`, channel failing to open on literally every
            # attempt, ~0.7s apart) -- no mic at all, instead of an
            # imperfect one. Reverted same day. Do not re-add an explicit
            # rate: here without first confirming format negotiation still
            # succeeds (check connect.log for audin_process_open errors).
            local mic_flag="/microphone:sys:alsa" usb_mic
            if usb_mic=$(usb_capture_card); then
                mic_flag="/microphone:sys:alsa,dev:plughw:CARD=${usb_mic}"
                log "USB microphone detected (ALSA card '${usb_mic}') — redirecting it"
            fi

            # See default_playback_card above — picks the first ALSA card
            # that can actually play audio, instead of trusting ALSA's own
            # index-0 default. Re-checked every attempt for the same
            # hot-plug-reordering reason as the mic.
            #
            # `hw:`, not `plughw:` (unlike the mic flag below): FreeRDP's
            # ALSA sound backend reuses this same `dev:` string for BOTH
            # the PCM stream AND an internal snd_mixer_attach() call for
            # volume control. `plughw:` is a PCM-only plugin type with no
            # corresponding CTL device, so the mixer attach fails outright
            # on it (confirmed live 2026-08-10: `amixer -D plughw:CARD=SB`
            # → "Invalid CTL plughw:CARD=SB") and that failure aborts the
            # whole rdpsnd channel before any audio plays, even though the
            # PCM side alone would have opened fine. `hw:` mixer-attaches
            # correctly, and plays standard 48kHz/S16_LE/stereo (what RDP
            # audio negotiates) without needing plughw's format
            # conversion — verified with speaker-test before switching.
            local sound_flag="/sound:sys:alsa" playback_card
            if playback_card=$(default_playback_card); then
                sound_flag="/sound:sys:alsa,dev:hw:CARD=${playback_card}"
                log "Playback ALSA card '${playback_card}' selected"
            fi

            # Webcam redirection (MS-RDPECAM, /dvc:rdpecam) — ON by
            # default when a /dev/video* device exists; set
            # SLIMEOS_ENABLE_CAMERA=0 in /etc/slimeos/config to opt out.
            # Requires the +slimeos5 FreeRDP rebuild install.sh pins
            # (Debian's archive build lacks the channel entirely, and its
            # source has three camera bugs we patch — see
            # membrane/freerdp/camera-patches/README.md). Confirmed
            # working end-to-end 2026-07-17: Logitech C920 → Azure
            # Windows Brain, live picture in the Camera app. The camera
            # frames are MJPG-decoded and H264-re-encoded in software on
            # the Membrane, so expect CPU cost and some lag on weak
            # hardware while an app is actively capturing.
            local cam_flag=""
            if [[ "${SLIMEOS_ENABLE_CAMERA:-1}" == "1" ]] && compgen -G "/dev/video*" >/dev/null; then
                cam_flag="/dvc:rdpecam"
                log "Camera device present — enabling webcam redirection (SLIMEOS_ENABLE_CAMERA=0 to disable)"
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
            # Tried /action-script:action-noop.sh here 2026-08-14 to stop
            # xfreerdp3 intercepting Ctrl+Alt+Enter/C/M locally instead of
            # forwarding them to the Brain (Google Sheets' Ctrl+Alt+M
            # "insert comment" shortcut never arrived because of this) --
            # reverted same day: contrary to --help's description, FreeRDP
            # calls the script at PRE-CONNECT time expecting real output,
            # not just at runtime keypresses; a script producing no output
            # aborted every connection outright with
            # ERRCONNECT_PRE_CONNECT_FAILED (exit 136), confirmed live
            # against all three Brains. The actual action-script response
            # contract needs reading FreeRDP's source, not just --help,
            # before trying this again — see membrane/freerdp/
            # action-noop.sh's own header for the postmortem.
            set +e
            xfreerdp3 \
                /v:"${vm_host}:${vm_port}" \
                /u:"${slime_username}" \
                /p:"${rdp_pass}" \
                /sec:rdp:off \
                /cert:ignore \
                /network:"${RDP_NETWORK:-auto}" \
                ${RES_FLAGS} \
                /dynamic-resolution \
                ${sound_flag} \
                ${mic_flag} \
                ${cam_flag} \
                /drive:usb,"/media/$(id -un)" \
                /log-level:WARN \
                ${SLIMEOS_FREERDP_EXTRA_FLAGS} >> "$FREERDP_LOG_FILE" 2>&1 &
            local xpid=$! cancelled=false

            # The lockscreen page never hears anything else from us for
            # the entire duration of a session -- xfreerdp3's own
            # Xwayland-hosted window is what's actually on screen the
            # whole time, so it stayed rendering the "connecting" screen
            # (with its infinite pulseRing spinner) full-tilt, unseen, for
            # the session's whole lifetime. WPE WebKit has no
            # page-visibility signal for "occluded by another Wayland
            # surface" the way a real browser tab would, so nothing ever
            # throttled it on its own. Confirmed live 2026-08-10:
            # WPEWebProcess sustained ~84% CPU through an entire RDP
            # session, contributing to real mic-capture underruns (ALSA
            # buffer starvation from CPU contention) -- though the bigger
            # single contributor turned out to be the #app root's own
            # ambientDrift background animation (removed outright, see
            # its CSS comment; that alone was ~254% CPU even at idle).
            # sessionActive swaps to a static screen with no infinite
            # animation of its own (see index.html's renderSessionActive)
            # so the pulseRing spinner isn't left running for the session's
            # whole duration either.
            emit_state sessionActive "$(jq -nc --arg n "$brain_name" \
                '{brainName:$n}')"

            while kill -0 "$xpid" 2>/dev/null; do
                if read -t 1 -r line <&0; then
                    local ev_type
                    ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                    if [[ "$ev_type" == "cancelConnect" || "$ev_type" == "forceBack" ]]; then
                        kill "$xpid" 2>/dev/null || true
                        # xfreerdp3 can catch SIGTERM and wedge in its own
                        # abort/cleanup path instead of actually exiting --
                        # confirmed live 2026-08-10: a frozen session's
                        # process logged "Caught signal 'Terminated'" /
                        # freerdp_abort_connect_context, then sat at ~86%
                        # CPU for 90+ seconds, never dying. The `wait`
                        # below is blocking, so a wedged process here
                        # froze the WHOLE coordinator (and the kiosk
                        # screen with it) even though the hotkey fired
                        # correctly at the bridge level -- SIGKILL was the
                        # only thing that unstuck it. Give SIGTERM a
                        # bounded grace period, then escalate.
                        local kill_waited=0
                        while (( kill_waited < 5 )) && kill -0 "$xpid" 2>/dev/null; do
                            sleep 1
                            kill_waited=$((kill_waited + 1))
                        done
                        if kill -0 "$xpid" 2>/dev/null; then
                            log "xfreerdp3 (pid $xpid) still alive 5s after SIGTERM — sending SIGKILL"
                            kill -KILL "$xpid" 2>/dev/null || true
                        fi
                        cancelled=true
                        break
                    else
                        # A successful systemctl call here means the machine is
                        # about to power off/reboot regardless -- no need to
                        # kill xfreerdp ourselves, the OS shutdown handles that.
                        try_handle_power_event "$ev_type" || :
                        try_handle_crash_report "$ev_type" "$line" || :
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
                        if [[ "$ev_type" == "back" || "$ev_type" == "forceBack" ]]; then
                            backed_out=true
                            break
                        else
                            try_handle_power_event "$ev_type" || :
                            try_handle_crash_report "$ev_type" "$line" || :
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

            local is_auth_failure=false
            case "$err_hint" in
                ERRCONNECT_AUTHENTICATION_FAILED|ERRCONNECT_LOGON_FAILURE) is_auth_failure=true ;;
            esac

            # A server-sourced credential's auth failure gets special
            # handling: a human never typed this password, so the generic
            # "Re-enter password" prompt is worse than useless here -- it
            # implies an action the user can't meaningfully take. First
            # failure: silently re-fetch once (covers the motivating case --
            # Tommy fixing a wrong password via the admin endpoint while the
            # kiosk is mid-retry) and reconnect without ever showing an
            # error screen. This is ONE bounded automatic retry, not a
            # loop, so it doesn't reopen the "blind retries can lock a
            # Windows account" risk noted above (a single extra attempt,
            # same cost as a human clicking "Try again" once). Second
            # consecutive failure: fall through to a distinct error state
            # with no "Re-enter password" button.
            if [[ "$is_auth_failure" == true && "$cred_source" == "server" && "$server_auth_retried" != true ]]; then
                server_auth_retried=true
                log "Server-stored credential rejected for paid brain $brain_id — re-fetching once before surfacing an error"
                phase="credentials"
                # Only 2 loops enclose this point (the connect-attempt loop,
                # then the outer phase-dispatch loop) -- unlike the
                # `continue 3`s below, which run from one level deeper,
                # inside the error-wait loop this same fast-failure section
                # is about to enter.
                continue 2
            fi

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

            local hide_reenter=false
            if [[ "$is_auth_failure" == true && "$cred_source" == "server" ]]; then
                # Second consecutive server-credential auth failure -- the
                # re-fetch above didn't help. Override the message; suppress
                # the button that would prompt for a password this user was
                # never given.
                message="This Brain's saved sign-in details aren't working. This has been flagged for Tommy to fix."
                hide_reenter=true
            fi

            emit_state error "$(jq -nc --arg n "$brain_name" --arg m "$message" --arg d "$detail" --argjson hr "$hide_reenter" \
                '{brainName:$n,message:$m,detail:$d,hideReenterPassword:$hr}')"

            while true; do
                local line ev_type
                line=$(read_event) || return 0
                ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
                case "$ev_type" in
                    retry)
                        if [[ "$is_auth_failure" == true && "$cred_source" == "server" ]]; then
                            # "Try again" on the distinct server-credential
                            # error screen means "re-check whether Tommy
                            # fixed it yet", not "immediately resubmit the
                            # same rejected password".
                            server_auth_retried=false
                            phase="credentials"
                            continue 3
                        fi
                        continue 2
                        ;;
                    reenterPassword)
                        if [[ "$cred_source" == "server" ]]; then
                            # This button isn't rendered when
                            # hideReenterPassword is true, so reaching here
                            # would only happen via a stale frontend event --
                            # treat it the same as retry: re-fetch, there's
                            # no local cred_file for this brain to delete.
                            server_auth_retried=false
                            phase="credentials"
                            continue 3
                        fi
                        rm -f "$cred_file"
                        phase="credentials"
                        continue 3
                        ;;
                    back|forceBack) return 0 ;;
                    *)
                        try_handle_power_event "$ev_type" || :
                        try_handle_crash_report "$ev_type" "$line" || :
                        ;;
                esac
            done
        done
    done
}
