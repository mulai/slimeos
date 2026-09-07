#!/usr/bin/env bash
# Slime OS — Send Feedback settings tab
#
# `source`d by membrane/session/coordinator.sh, same shape as changelog.sh's
# do_changelog() and support.sh's do_support(): relies on coordinator.sh's
# own log()/emit_state()/read_event() helpers. `mode` is always "settings"
# -- there is no boot-mode variant of this screen.
#
# Lets a user file a bug report / feature request / general note straight
# from the kiosk, from Settings > Help > Send Feedback. The submission is a
# single best-effort POST to the slimeos.com feedback endpoint, which
# scrubs it, opens a public GitHub issue (labels `user-feedback` + the
# category), and records the full payload in D1 for later triage. There is
# NO on-device account or auth -- the endpoint is public and unauthenticated
# (same posture as crash-reporting.sh's /api/report-error), rate-capped
# server-side.
#
# What rides along, and what deliberately does NOT
# -------------------------------------------------
# feedback_collect_diagnostics() gathers ONLY non-identifying environment
# facts that help pin down an issue: Membrane version, hardware profile,
# kernel / Debian / arch, RAM, uptime, the active link's type + MTU, the
# WireGuard link's MTU, tunnel up/down, NetworkManager connectivity state,
# a DNS-server COUNT (never the addresses), how many Brains are saved / how
# many are paid, and a coarse guess at the paired Brain's stack. It never
# collects: WiFi SSIDs, IP or MAC addresses, WireGuard keys, Brain
# hostnames, the recovery PIN, Slime ID tokens, or anything typed into a
# form other than the feedback message itself. The message + the serialized
# diagnostics are additionally run through the server's scrubPii() before
# anything is stored or posted -- defense in depth, same as
# crash-reporting.sh's scrub_pii(). The "network provider / country" line
# people see on a triaged report is derived SERVER-SIDE from Cloudflare's
# edge metadata (request.cf) -- the device never sends its public IP.
#
# The whole diagnostics gather runs under `set +e` (restored before it
# returns) because it shells out to a dozen optional tools/paths, any of
# which can be absent on a given image -- a failure there must degrade to a
# missing field, never crash the coordinator under set -euo pipefail. The
# caller still guards it with `|| echo '{}'`.

FEEDBACK_ENDPOINT="${SLIMEOS_FEEDBACK_ENDPOINT:-https://www.slimeos.com/api/device/feedback}"

# Best-effort, non-identifying environment snapshot. Emits a single compact
# JSON object on stdout. See this file's header for the collect/omit policy.
feedback_collect_diagnostics() {
    set +e

    local kernel arch debian_ver mem_kb uptime_s mver rel hw_profile
    kernel=$(uname -r 2>/dev/null)
    arch=$(uname -m 2>/dev/null)
    debian_ver=$(cat /etc/debian_version 2>/dev/null)
    mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    uptime_s=$(awk '{print int($1); exit}' /proc/uptime 2>/dev/null)
    mver=$(cat "$CONFIG_DIR/version" 2>/dev/null); [[ -n "$mver" ]] || mver="unknown"
    rel=$(cat "$CONFIG_DIR/changelog-released-at" 2>/dev/null)
    hw_profile="unknown"
    if [[ -f "$CONFIG_DIR/hw-profile-applied" ]]; then
        hw_profile=$(awk -F= '/^profile=/{print $2; exit}' "$CONFIG_DIR/hw-profile-applied" 2>/dev/null)
        [[ -n "$hw_profile" ]] || hw_profile="unknown"
    fi

    # Active default-route interface -> its type + MTU. Interface NAME is
    # not identifying (eth0/wlan0/...); the MTU is the actual troubleshooting
    # signal the note asked for.
    local defif iftype ifmtu
    defif=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [[ -n "$defif" ]]; then
        ifmtu=$(cat "/sys/class/net/$defif/mtu" 2>/dev/null)
        if [[ -d "/sys/class/net/$defif/wireless" ]]; then iftype="wifi"; else iftype="ethernet"; fi
    fi

    local wg_mtu tunnel
    [[ -r /sys/class/net/wg0/mtu ]] && wg_mtu=$(cat /sys/class/net/wg0/mtu 2>/dev/null)
    tunnel="down"; ip link show wg0 &>/dev/null && tunnel="up"

    local nm_conn nm_type dns_count
    nm_conn=$(nmcli -t networking connectivity 2>/dev/null)
    nm_type=$(nmcli -t -f TYPE,STATE connection show --active 2>/dev/null | awk -F: '$2=="activated"{print $1; exit}')
    dns_count=$(awk '/^nameserver /{n++} END{print n+0}' /etc/resolv.conf 2>/dev/null)

    # Brains overview -- counts + the most-recently-connected one's `kind`,
    # never names or hosts.
    local brain_count paid_count last_kind
    brain_count=$(jq 'length' "$BRAINS_FILE" 2>/dev/null); [[ -n "$brain_count" ]] || brain_count=0
    paid_count=$(jq '[.[] | select(.kind == "paid")] | length' "$BRAINS_FILE" 2>/dev/null); [[ -n "$paid_count" ]] || paid_count=0
    last_kind=$(jq -r 'sort_by(.lastConnected // "") | reverse | .[0].kind // ""' "$BRAINS_FILE" 2>/dev/null)

    # Coarse guess at the paired Brain's stack. FreeRDP runs at
    # /log-level:WARN (see connect.sh), so connect.log rarely has enough to
    # be authoritative -- an xrdp cert CN ("www.xrdp.org") is the one strong
    # tell that sometimes surfaces even at WARN. Otherwise fall back to the
    # brain `kind`: a paid Brain is a Windows node, a free one is Linux/xRDP
    # (see README's licensing section). Always suffixed so a reader knows
    # it's inferred, not observed.
    local brain_stack="unknown"
    if [[ -f "$FREERDP_LOG_FILE" ]] && grep -qi 'xrdp' "$FREERDP_LOG_FILE" 2>/dev/null; then
        brain_stack="linux-xrdp (observed)"
    elif [[ "$last_kind" == "paid" ]]; then
        brain_stack="windows (inferred from tier)"
    elif [[ "$last_kind" == "free" ]]; then
        brain_stack="linux-xrdp (inferred from tier)"
    fi

    local frdp_ver
    frdp_ver=$(xfreerdp3 /version 2>/dev/null | head -n1)

    jq -nc \
        --arg kernel "${kernel:-}" --arg arch "${arch:-}" --arg debian "${debian_ver:-}" \
        --arg mem_kb "${mem_kb:-}" --arg uptime_s "${uptime_s:-}" \
        --arg hw_profile "${hw_profile:-unknown}" --arg mver "${mver:-unknown}" --arg rel "${rel:-}" \
        --arg defif "${defif:-}" --arg iftype "${iftype:-}" --arg ifmtu "${ifmtu:-}" \
        --arg wg_mtu "${wg_mtu:-}" --arg tunnel "${tunnel:-}" --arg nm_conn "${nm_conn:-}" \
        --arg nm_type "${nm_type:-}" --arg dns_count "${dns_count:-0}" \
        --arg brain_count "${brain_count:-0}" --arg paid_count "${paid_count:-0}" \
        --arg brain_stack "${brain_stack:-unknown}" --arg frdp_ver "${frdp_ver:-}" \
        '# `// null` rescues the empty stream tonumber? yields on an
         # unreadable/non-numeric source -- without it, one missing numeric
         # field would collapse the WHOLE object to zero output and lose
         # every diagnostic. Empty strings likewise map to null, not "".
         {
          membrane_version: $mver,
          membrane_released_at: ($rel | select(. != "") // null),
          hardware_profile: $hw_profile,
          kernel: ($kernel | select(. != "") // null),
          arch: ($arch | select(. != "") // null),
          debian_version: ($debian | select(. != "") // null),
          mem_total_kb: (($mem_kb | tonumber?) // null),
          uptime_s: (($uptime_s | tonumber?) // null),
          net: {
            default_iface: ($defif | select(. != "") // null),
            iface_type: ($iftype | select(. != "") // null),
            mtu: (($ifmtu | tonumber?) // null),
            wg_mtu: (($wg_mtu | tonumber?) // null),
            tunnel: $tunnel,
            nm_connectivity: ($nm_conn | select(. != "") // null),
            nm_active_type: ($nm_type | select(. != "") // null),
            dns_server_count: (($dns_count | tonumber?) // null)
          },
          brain: {
            saved_count: (($brain_count | tonumber?) // null),
            paid_count: (($paid_count | tonumber?) // null),
            stack_guess: $brain_stack
          },
          freerdp_version: ($frdp_ver | select(. != "") // null)
        }'
    local rc=$?

    set -e
    return $rc
}

do_feedback() {
    local mode="$1"
    local status="idle" error="" issue_url="" category="bug"

    while true; do
        local mver; mver=$(cat "$CONFIG_DIR/version" 2>/dev/null || echo "unknown")
        emit_state feedbackSettings "$(jq -nc \
            --arg mode "$mode" --arg status "$status" --arg category "$category" \
            --arg error "$error" --arg issueUrl "$issue_url" --arg version "$mver" \
            '{mode:$mode, status:$status, category:$category,
              error:(if $error == "" then null else $error end),
              issueUrl:(if $issueUrl == "" then null else $issueUrl end),
              version:$version}')"
        error=""

        local line ev_type
        line=$(read_event) || return 0
        ev_type=$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)
        case "$ev_type" in
            feedbackSubmit)
                category=$(jq -r '.category // "other"' <<<"$line")
                case "$category" in bug|feature|other) ;; *) category="other" ;; esac

                local message
                message=$(jq -r '.message // ""' <<<"$line")
                message="$(printf '%s' "$message" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if [[ "${#message}" -lt 3 ]]; then
                    error="Add a little more detail so we can act on it."
                    continue
                fi
                # Server also caps this; trimming here keeps an accidental
                # paste from bloating the request body.
                message="${message:0:4000}"

                status="sending"
                emit_state feedbackSettings "$(jq -nc --arg mode "$mode" --arg category "$category" --arg version "$mver" \
                    '{mode:$mode, status:"sending", category:$category, error:null, issueUrl:null, version:$version}')"

                local diag payload resp rc ok url
                diag=$(feedback_collect_diagnostics || echo '{}')
                payload=$(jq -nc --arg category "$category" --arg message "$message" \
                    --arg mver "$mver" --argjson diagnostics "$diag" \
                    '{category:$category, message:$message, membrane_version:$mver, diagnostics:$diagnostics}')

                log "Feedback: submitting ($category, ${#message} chars)"
                set +e
                resp=$(curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
                    -d "$payload" "$FEEDBACK_ENDPOINT" 2>/dev/null)
                rc=$?
                set -e

                if [[ $rc -ne 0 ]]; then
                    log "Feedback submit failed (curl exit $rc)"
                    status="error"
                    error="Couldn't send just now — check your connection and try again."
                    continue
                fi
                ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null || echo false)
                if [[ "$ok" != "true" ]]; then
                    log "Feedback submit rejected: ${resp:0:200}"
                    status="error"
                    error=$(jq -r '.error // "The server couldn'\''t accept that right now."' <<<"$resp" 2>/dev/null || echo "The server couldn't accept that right now.")
                    continue
                fi
                url=$(jq -r '.issue_url // ""' <<<"$resp" 2>/dev/null || echo "")
                issue_url="$url"
                status="sent"
                log "Feedback sent ($category)${url:+ -> $url}"
                ;;
            feedbackReset)
                status="idle"; issue_url=""; error=""
                ;;
            settingsTab)
                [[ "$mode" == "settings" ]] || continue
                SETTINGS_NEXT_TAB=$(jq -r '.tab // empty' <<<"$line")
                [[ -n "$SETTINGS_NEXT_TAB" ]] && return 0
                ;;
            back) return 0 ;;
            forceBack) return 0 ;;
            *)
                try_handle_power_event "$ev_type" || :
                try_handle_crash_report "$ev_type" "$line" || :
                ;;
        esac
    done
}
