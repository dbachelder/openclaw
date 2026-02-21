#!/usr/bin/env bash
# openclaw-watchdog.sh — Independent health monitor for the OpenClaw gateway
#
# Runs as a separate systemd service. Monitors gateway health and escalates
# through recovery steps if it's down.
#
# Escalation ladder:
#   1. Restart the gateway (with cooldown)
#   2. Restore config from known-good backup + restart
#   3. Restore dist from fallback + restore config + restart
#   4. Give up — notify and stay down (don't make it worse)
#
# Flap detection: if gateway oscillates healthy/unhealthy rapidly (crash loop
# where systemd restarts it before the watchdog notices), detect via flap
# count and treat as a restart loop.

set -euo pipefail

GATEWAY_URL="http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/"
GATEWAY_SERVICE="openclaw-gateway.service"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
CONFIG_GOOD="$HOME/.openclaw/openclaw.json.known-good"
SRC_DIR="/home/dan/src/openclaw"
DIST_DIR="${SRC_DIR}/dist"
FALLBACK_DIR="${SRC_DIR}/.dist-fallback"
FALLBACK_LOCK="/tmp/openclaw-fallback-active"
STATE_FILE="/tmp/openclaw-watchdog-state"
RESTART_LOG="/tmp/openclaw-watchdog-restarts"
FLAP_LOG="/tmp/openclaw-watchdog-flaps"

CHECK_INTERVAL=15        # seconds between checks
FAIL_THRESHOLD=4         # consecutive failures before escalating
MAX_ESCALATION=3         # highest escalation level
COOLDOWN_AFTER_RESTART=60  # seconds to wait after a restart before checking again
RESTART_LOOP_WINDOW=600    # 10 minutes
RESTART_LOOP_MAX=3         # max restarts in window before giving up
FLAP_WINDOW=300            # 5 minutes
FLAP_MAX=6                 # max healthy→unhealthy transitions before treating as crash loop
STABLE_UPTIME=120          # seconds of continuous health before snapshotting config as known-good

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*"; }

check_health() {
    if ! systemctl --user is-active "$GATEWAY_SERVICE" &>/dev/null; then
        return 1
    fi
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL" --max-time 5 2>/dev/null || echo "000")
    if [[ "$http_code" == "000" ]]; then
        return 1
    fi
    return 0
}

record_restart() {
    echo "$(date +%s)" >> "$RESTART_LOG"
}

record_flap() {
    echo "$(date +%s)" >> "$FLAP_LOG"
}

count_recent_events() {
    local logfile=$1 window=$2
    if [[ ! -f "$logfile" ]]; then
        echo 0
        return
    fi
    local cutoff now
    now=$(date +%s)
    cutoff=$(( now - window ))
    awk -v c="$cutoff" '$1 >= c' "$logfile" | wc -l
}

in_restart_loop() {
    local restart_count flap_count
    restart_count=$(count_recent_events "$RESTART_LOG" "$RESTART_LOOP_WINDOW")
    flap_count=$(count_recent_events "$FLAP_LOG" "$FLAP_WINDOW")
    if (( restart_count >= RESTART_LOOP_MAX )) || (( flap_count >= FLAP_MAX )); then
        return 0
    fi
    return 1
}

prune_log() {
    local logfile=$1 window=$2
    if [[ -f "$logfile" ]]; then
        local cutoff
        cutoff=$(( $(date +%s) - window * 2 ))
        awk -v c="$cutoff" '$1 >= c' "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
    fi
}

set_state() {
    echo "$1:$2" > "$STATE_FILE"
}

snapshot_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
            cp "$CONFIG_FILE" "$CONFIG_GOOD"
            log "Config snapshot saved as known-good"
        else
            log "⚠️  Config is not valid JSON — skipping snapshot"
        fi
    fi
}

escalate() {
    local level=$1

    if in_restart_loop; then
        log "🛑 Restart/flap loop detected — backing off"
        log "🛑 Manual intervention required. Not restarting."
        return 1
    fi

    case $level in
        1)
            log "⚡ Level 1: Restarting gateway"
            record_restart
            systemctl --user restart "$GATEWAY_SERVICE"
            ;;
        2)
            log "⚠️  Level 2: Restoring known-good config + restart"
            if [[ -f "$CONFIG_GOOD" ]]; then
                cp "$CONFIG_GOOD" "$CONFIG_FILE"
                log "Config restored from known-good backup"
            else
                log "No known-good config found, skipping config restore"
            fi
            record_restart
            systemctl --user restart "$GATEWAY_SERVICE"
            ;;
        3)
            log "🔴 Level 3: Restoring fallback dist + config + restart"
            if [[ -d "$FALLBACK_DIR" ]]; then
                rm -rf "$DIST_DIR"
                cp -r "$FALLBACK_DIR" "$DIST_DIR"
                touch "$FALLBACK_LOCK"
                log "Dist restored from fallback"
            else
                log "No fallback dist found — cannot restore"
            fi
            if [[ -f "$CONFIG_GOOD" ]]; then
                cp "$CONFIG_GOOD" "$CONFIG_FILE"
                log "Config restored from known-good backup"
            fi
            record_restart
            systemctl --user restart "$GATEWAY_SERVICE"
            ;;
        *)
            log "❌ Max escalation reached — not restarting"
            return 1
            ;;
    esac
    return 0
}

# Save initial known-good config if none exists
if [[ ! -f "$CONFIG_GOOD" ]] && [[ -f "$CONFIG_FILE" ]]; then
    snapshot_config
fi

log "Watchdog started (check=${CHECK_INTERVAL}s, threshold=${FAIL_THRESHOLD}, cooldown=${COOLDOWN_AFTER_RESTART}s, loop=${RESTART_LOOP_MAX}/${RESTART_LOOP_WINDOW}s, flap=${FLAP_MAX}/${FLAP_WINDOW}s)"

fail_count=0
escalation_level=0
backed_off=false
was_healthy=true
last_healthy_at=0

while true; do
    prune_log "$RESTART_LOG" "$RESTART_LOOP_WINDOW"
    prune_log "$FLAP_LOG" "$FLAP_WINDOW"

    if check_health; then
        now=$(date +%s)

        # Detect flapping: was unhealthy, now healthy again
        if [[ "$was_healthy" == "false" ]]; then
            record_flap
            local_flaps=$(count_recent_events "$FLAP_LOG" "$FLAP_WINDOW")
            log "Gateway came back (flap ${local_flaps}/${FLAP_MAX} in ${FLAP_WINDOW}s)"

            if (( local_flaps >= FLAP_MAX )); then
                log "🛑 Flap loop detected — gateway is crash-looping under systemd restart"
                log "🛑 Stopping gateway to break the loop"
                systemctl --user stop "$GATEWAY_SERVICE"
                backed_off=true
                was_healthy=false
                fail_count=0
                escalation_level=0
                set_state 0 0
                log "Gateway stopped. Manual intervention required."
                sleep 60
                continue
            fi

            last_healthy_at=$now
        fi

        # Only snapshot config after sustained uptime
        if (( fail_count > 0 )) && (( last_healthy_at > 0 )); then
            uptime_secs=$(( now - last_healthy_at ))
            if (( uptime_secs >= STABLE_UPTIME )); then
                log "✅ Gateway stable for ${uptime_secs}s — snapshotting config"
                snapshot_config
                last_healthy_at=0  # don't snapshot again until next recovery
            fi
        elif (( fail_count > 0 )); then
            last_healthy_at=$now
        fi

        if (( fail_count > 0 )) || [[ "$backed_off" == "true" ]]; then
            log "✅ Gateway recovered (was at fail=${fail_count}, escalation=${escalation_level})"
        fi

        fail_count=0
        escalation_level=0
        backed_off=false
        was_healthy=true
        set_state 0 0
    else
        # Track transition from healthy to unhealthy
        was_healthy=false

        (( fail_count++ )) || true
        log "Gateway unhealthy (fail ${fail_count}/${FAIL_THRESHOLD})"

        if (( fail_count >= FAIL_THRESHOLD )); then
            if (( escalation_level < MAX_ESCALATION )); then
                (( escalation_level++ )) || true
                log "Escalating to level ${escalation_level}"
                if escalate "$escalation_level"; then
                    fail_count=0
                    set_state 0 "$escalation_level"
                    log "Waiting ${COOLDOWN_AFTER_RESTART}s cooldown after restart..."
                    sleep "$COOLDOWN_AFTER_RESTART"
                    continue
                else
                    backed_off=true
                    log "Backing off — checking every 60s until manual fix"
                    set_state "$fail_count" "$escalation_level"
                    sleep 60
                    continue
                fi
            else
                if [[ "$backed_off" != "true" ]]; then
                    log "❌ All escalation levels exhausted — waiting for manual intervention"
                    backed_off=true
                fi
                sleep 60
                continue
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
