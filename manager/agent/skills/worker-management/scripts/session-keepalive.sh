#!/bin/bash
# session-keepalive.sh - Matrix room session keepalive management
#
# OpenClaw resets sessions after idleMinutes of inactivity (configured in
# openclaw.json: session.resetByChannel.matrix.idleMinutes = 10080, i.e. 7 days).
# This script scans all known rooms once per day and reports rooms approaching
# expiry. On request, it sends a keepalive message mentioning all room members
# to reset their idle timers.
#
# Usage:
#   session-keepalive.sh --action scan
#   session-keepalive.sh --action keepalive --room <room_id>

set -euo pipefail

MATRIX_URL="http://127.0.0.1:6167"
MATRIX_TOKEN="${MANAGER_MATRIX_TOKEN:-}"

REGISTRY_FILE="${HOME}/manager-workspace/workers-registry.json"
LIFECYCLE_FILE="${HOME}/manager-workspace/worker-lifecycle.json"
LAST_SCAN_FILE="${HOME}/manager-workspace/.session-scan-last-run"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Must match openclaw.json session.resetByChannel.matrix.idleMinutes
IDLE_MINUTES=10080        # 7 days
WARN_BEFORE_MINUTES=1440  # warn 1 day before expiry (threshold: 6 days idle)

_log() {
    echo "[session-keepalive $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

_matrix_get() {
    curl -s -H "Authorization: Bearer ${MATRIX_TOKEN}" "${MATRIX_URL}$1"
}

_matrix_send() {
    local room_id="$1"
    local body="$2"
    local encoded_room
    encoded_room=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    local txn_id="keepalive-$(date -u +%s)-$$"
    local payload
    payload=$(jq -n --arg b "$body" '{"msgtype":"m.text","body":$b}')
    curl -s -X PUT \
        -H "Authorization: Bearer ${MATRIX_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${MATRIX_URL}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}"
}

# Get timestamp (seconds) of the last m.room.message in a room; 0 if none
_room_last_msg_ts_s() {
    local room_id="$1"
    local encoded
    encoded=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    local filter_enc='%7B%22types%22%3A%5B%22m.room.message%22%5D%7D'
    local ts_ms
    ts_ms=$(_matrix_get "/_matrix/client/v3/rooms/${encoded}/messages?dir=b&limit=1&filter=${filter_enc}" | \
        jq -r '.chunk[0].origin_server_ts // 0' 2>/dev/null || echo 0)
    echo $(( ts_ms / 1000 ))
}

# Get joined member user IDs for a room (newline-separated)
_room_members() {
    local room_id="$1"
    local encoded
    encoded=$(echo "$room_id" | sed 's/!/%21/g; s/:/%3A/g')
    _matrix_get "/_matrix/client/v3/rooms/${encoded}/members?membership=join" | \
        jq -r '.chunk[].state_key' 2>/dev/null
}

# Look up worker name from Matrix user ID; empty if not a worker
_worker_from_matrix_id() {
    [ -f "$REGISTRY_FILE" ] || return
    jq -r --arg id "$1" \
        '.workers | to_entries[] | select(.value.matrix_user_id == $id) | .key' \
        "$REGISTRY_FILE" 2>/dev/null
}

# Emit all known room IDs as TSV: <room_id>\t<type>\t<name>
# type is "worker" or "project"
_collect_rooms() {
    if [ -f "$REGISTRY_FILE" ]; then
        jq -r '.workers | to_entries[] | "\(.value.room_id)\tworker\t\(.key)"' \
            "$REGISTRY_FILE" 2>/dev/null
    fi
    for meta in "${HOME}/hiclaw-fs/shared/projects"/*/meta.json; do
        [ -f "$meta" ] || continue
        local status room_id name
        status=$(jq -r '.status // empty' "$meta" 2>/dev/null)
        room_id=$(jq -r '.room_id // empty' "$meta" 2>/dev/null)
        name=$(jq -r '.title // .name // empty' "$meta" 2>/dev/null)
        [ "$status" = "active" ] && [ -n "$room_id" ] || continue
        printf '%s\tproject\t%s\n' "$room_id" "${name:-unknown}"
    done
}

# ─── Actions ─────────────────────────────────────────────────────────────────

action_scan() {
    # Guard: skip if last scan was less than 23 hours ago
    if [ -f "$LAST_SCAN_FILE" ]; then
        local last_run now_s
        last_run=$(cat "$LAST_SCAN_FILE" 2>/dev/null || echo 0)
        now_s=$(date -u +%s)
        if [ $(( now_s - last_run )) -lt $(( 23 * 3600 )) ]; then
            echo "SCAN_RESULT: skipped"
            return 0
        fi
    fi

    local now_s
    now_s=$(date -u +%s)
    # Rooms are considered near-expiry when they've been idle >= (IDLE - WARN_BEFORE) minutes
    local threshold_s=$(( (IDLE_MINUTES - WARN_BEFORE_MINUTES) * 60 ))
    local found_any=false

    _log "Scanning Matrix rooms for near-expiry sessions (threshold: ${threshold_s}s idle)..."

    while IFS=$'\t' read -r room_id room_type room_name; do
        [ -n "$room_id" ] || continue
        local last_ts_s
        last_ts_s=$(_room_last_msg_ts_s "$room_id")
        if [ "$last_ts_s" -eq 0 ]; then
            _log "  [$room_type] $room_name ($room_id): no messages, skipping"
            continue
        fi
        local idle_s=$(( now_s - last_ts_s ))
        local idle_h=$(( idle_s / 3600 ))
        if [ "$idle_s" -ge "$threshold_s" ]; then
            _log "  [$room_type] $room_name ($room_id): idle ${idle_h}h — NEAR EXPIRY"
            printf 'NEAR_EXPIRY_ROOM: %s\t%s\t%s\t%sh\n' "$room_id" "$room_type" "$room_name" "$idle_h"
            found_any=true
        else
            _log "  [$room_type] $room_name ($room_id): idle ${idle_h}h — OK"
        fi
    done < <(_collect_rooms)

    date -u +%s > "$LAST_SCAN_FILE"

    if [ "$found_any" = false ]; then
        echo "SCAN_RESULT: all_ok"
    else
        echo "SCAN_RESULT: near_expiry"
    fi
}

action_keepalive() {
    local room_id="$1"
    _log "Sending keepalive to room $room_id"

    local members
    members=$(_room_members "$room_id")
    if [ -z "$members" ]; then
        _log "ERROR: Could not get members for room $room_id"
        return 1
    fi

    # Wake any stopped Worker containers first
    local woke_any=false
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        local worker_name
        worker_name=$(_worker_from_matrix_id "$member")
        [ -n "$worker_name" ] || continue
        local container_status="unknown"
        if [ -f "$LIFECYCLE_FILE" ]; then
            container_status=$(jq -r --arg w "$worker_name" \
                '.workers[$w].container_status // "unknown"' \
                "$LIFECYCLE_FILE" 2>/dev/null)
        fi
        if [ "$container_status" = "stopped" ] || [ "$container_status" = "exited" ]; then
            _log "Worker $worker_name is stopped — waking up"
            bash "${SCRIPTS_DIR}/lifecycle-worker.sh" --action start --worker "$worker_name" || true
            woke_any=true
        fi
    done <<< "$members"

    if [ "$woke_any" = true ]; then
        _log "Waiting 30 seconds for workers to start..."
        sleep 30
    fi

    # Build mention string and send
    local mention_str=""
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        mention_str="${mention_str}${member} "
    done <<< "$members"
    mention_str="${mention_str% }"

    local body="[Session keepalive] ${mention_str} — maintaining conversation history for this room."
    _matrix_send "$room_id" "$body" | jq -r '.event_id // "ERROR"' 2>/dev/null
    _log "Keepalive message sent to room $room_id"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────

ACTION=""
ROOM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action) ACTION="$2"; shift 2 ;;
        --room)   ROOM="$2";   shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MATRIX_TOKEN" ]; then
    echo "ERROR: MANAGER_MATRIX_TOKEN is not set" >&2
    exit 1
fi

if [ -z "$ACTION" ]; then
    echo "Usage: $0 --action <scan|keepalive> [--room <room_id>]" >&2
    exit 1
fi

case "$ACTION" in
    scan)
        action_scan
        ;;
    keepalive)
        if [ -z "$ROOM" ]; then
            echo "ERROR: --room required for action 'keepalive'" >&2
            exit 1
        fi
        action_keepalive "$ROOM"
        ;;
    *)
        echo "ERROR: Unknown action '$ACTION'. Use: scan, keepalive" >&2
        exit 1
        ;;
esac
