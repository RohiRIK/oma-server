#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/snapshot.sh
# Hardened snapshot extraction, atomic persistence, and schema validation for oma-server.
set -euo pipefail

# Helper: Safely extract an option JSON object from hyprctl with timeout and JSON fallback
_query_hypr_option_json() {
    local opt_name="$1"
    local default_json="${2:-{\"int\":1}}"
    local raw=""

    raw=$(run_with_timeout 3 hyprctl -j getoption "$opt_name" 2>/dev/null || true)
    if [[ -z "$raw" ]] || [[ "$raw" =~ "no such option" ]] || ! printf "%s" "$raw" | jq empty 2>/dev/null; then
        printf "%s" "$default_json"
        return 1
    fi

    printf "%s" "$raw"
    return 0
}

# Captures runtime state from Hyprland and Quickshell, returning a canonical JSON document
capture_snapshot() {
    local qs_strategy="${1:-sigstop}"
    local current_uid="${UID:-$(id -u)}"

    # Pre-flight: Verify that the Hyprland IPC socket is responsive within timeout
    local monitors_raw=""
    if ! monitors_raw=$(run_with_timeout 3 hyprctl -j monitors 2>/dev/null) || [[ -z "$monitors_raw" ]] || ! printf "%s" "$monitors_raw" | jq empty 2>/dev/null; then
        if declare -F ui_log_fail >/dev/null 2>&1; then
            ui_log_fail "Unable to communicate with Hyprland via hyprctl IPC within 3s timeout." \
                "Ensure Hyprland is running and HYPRLAND_INSTANCE_SIGNATURE is set in this session."
        else
            echo "[ FAIL ] Unable to communicate with Hyprland via hyprctl IPC." >&2
        fi
        return 1
    fi

    # 1. Query compositor properties using timeout-bounded hyprctl -j getoption
    local anim_raw blur_raw shadow_raw vfr_raw
    anim_raw=$(_query_hypr_option_json "animations:enabled" '{"int":1}' || true)
    blur_raw=$(_query_hypr_option_json "decoration:blur:enabled" '{"int":1}' || true)
    if ! shadow_raw=$(_query_hypr_option_json "decoration:drop_shadow" '{"int":1}'); then
        shadow_raw=$(_query_hypr_option_json "decoration:shadow:enabled" '{"int":1}' || true)
    fi
    vfr_raw=$(_query_hypr_option_json "misc:vfr" '{"int":1}' || true)

    local anim_val blur_val shadow_val vfr_val
    anim_val=$(printf "%s" "$anim_raw" | jq -r 'if .int != null then .int elif .bool != null then (if .bool then 1 else 0 end) else 1 end' 2>/dev/null || echo "1")
    blur_val=$(printf "%s" "$blur_raw" | jq -r 'if .bool != null then .bool elif .int != null then (.int == 1) elif .set != null then .set else false end' 2>/dev/null || echo "false")
    shadow_val=$(printf "%s" "$shadow_raw" | jq -r 'if .bool != null then .bool elif .int != null then (.int == 1) elif .set != null then .set else false end' 2>/dev/null || echo "false")
    vfr_val=$(printf "%s" "$vfr_raw" | jq -r 'if .int != null then .int elif .bool != null then (if .bool then 1 else 0 end) else 1 end' 2>/dev/null || echo "1")

    # Sanitize extracted primitives
    [[ "$anim_val" =~ ^[01]$ ]] || anim_val=1
    [[ "$blur_val" == "true" || "$blur_val" == "false" ]] || blur_val=false
    [[ "$shadow_val" == "true" || "$shadow_val" == "false" ]] || shadow_val=false
    [[ "$vfr_val" =~ ^[01]$ ]] || vfr_val=1

    # 2. Query DPMS status across active monitors
    local dpms_val
    dpms_val=$(printf "%s" "$monitors_raw" | jq -r 'if (type == "array" and length > 0) then any(.[]; .dpmsStatus == true) else true end' 2>/dev/null || echo "true")
    [[ "$dpms_val" == "true" || "$dpms_val" == "false" ]] || dpms_val=true

    # 3. Discover omarchy-shell / quickshell PID scoped strictly to current user (${UID})
    local qs_pid="" was_running="false"
    qs_pid=$(pgrep -u "$current_uid" -x "omarchy-shell" 2>/dev/null | head -n 1 || true)
    if [[ -z "$qs_pid" ]]; then
        qs_pid=$(pgrep -u "$current_uid" -x "quickshell" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$qs_pid" && "$qs_pid" =~ ^[0-9]+$ ]] && (( qs_pid > 1 )); then
        was_running=true
    else
        qs_pid="null"
        was_running=false
    fi

    local action_label="SIGSTOP"
    if [[ "${qs_strategy,,}" != "sigstop" ]]; then
        action_label="SIGSTOP"
    fi

    # 4. Construct canonical JSON snapshot payload
    jq -n \
      --argjson timestamp "$(date +%s)" \
      --argjson session_uid "$current_uid" \
      --arg his "${HYPRLAND_INSTANCE_SIGNATURE:-unknown}" \
      --argjson anim "$anim_val" \
      --argjson blur "$blur_val" \
      --argjson shadow "$shadow_val" \
      --argjson vfr "$vfr_val" \
      --argjson dpms "$dpms_val" \
      --argjson qs_pid "$qs_pid" \
      --argjson qs_running "$was_running" \
      --arg qs_action "$action_label" \
      '{
        schema_version: 1,
        timestamp: $timestamp,
        session_uid: $session_uid,
        hyprland_instance_signature: $his,
        compositor_properties: {
          "animations:enabled": $anim,
          "decoration:blur:enabled": $blur,
          "decoration:drop_shadow": $shadow,
          "misc:vfr": $vfr,
          "dpms_status": $dpms
        },
        quickshell_state: {
          pid: $qs_pid,
          was_running: $qs_running,
          action_taken: $qs_action
        }
      }'
}

# Atomically writes and verifies a snapshot JSON artifact in tmpfs
write_snapshot_atomic() {
    local snapshot_json="$1"
    local target_file="$2"
    local tmp_file="${target_file}.tmp.$$"

    (
        umask 077
        printf "%s\n" "$snapshot_json" > "$tmp_file"
    )
    chmod 0600 "$tmp_file"

    if ! validate_snapshot "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    mv -f "$tmp_file" "$target_file"
    chmod 0600 "$target_file"
    return 0
}

# Strictly validates that a snapshot file exists, is owned by UID, is not a symlink,
# parses as valid JSON, and satisfies the required type/value schema.
validate_snapshot() {
    local file="$1"
    local current_uid="${UID:-$(id -u)}"

    if [[ ! -f "$file" ]] || [[ -L "$file" ]]; then
        return 1
    fi

    if [[ ! -O "$file" ]]; then
        return 1
    fi

    if ! jq empty "$file" 2>/dev/null; then
        return 1
    fi

    local is_valid
    is_valid=$(jq --argjson expected_uid "$current_uid" '
      (type == "object")
      and (has("timestamp") and (.timestamp | type == "number") and (.timestamp > 0))
      and (has("session_uid") and (.session_uid | type == "number") and (.session_uid == $expected_uid))
      and (has("hyprland_instance_signature") and (.hyprland_instance_signature | type == "string"))
      and (has("compositor_properties") and (.compositor_properties | type == "object"))
      and (.compositor_properties |
            (has("animations:enabled") and (.["animations:enabled"] | type == "number"))
            and (has("decoration:blur:enabled") and (.["decoration:blur:enabled"] | type == "boolean"))
            and (has("decoration:drop_shadow") and (.["decoration:drop_shadow"] | type == "boolean"))
            and (has("misc:vfr") and (.["misc:vfr"] | type == "number"))
            and (has("dpms_status") and (.dpms_status | type == "boolean"))
          )
      and (has("quickshell_state") and (.quickshell_state | type == "object"))
      and (.quickshell_state |
            (has("pid") and ((.pid == null) or ((.pid | type == "number") and (.pid > 1))))
            and (has("was_running") and (.was_running | type == "boolean"))
            and (has("action_taken") and (.action_taken | type == "string"))
          )
    ' "$file" 2>/dev/null || echo "false")

    if [[ "$is_valid" != "true" ]]; then
        return 1
    fi

    return 0
}
