#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/snapshot.sh
# Hardened snapshot extraction, atomic persistence, and schema validation for oma-server.
set -euo pipefail

# Helper: Safely extract an option JSON object from hyprctl with generous timeout for TCG/emulation
_query_hypr_option_json() {
    local opt_name="$1"
    local raw=""

    raw=$(run_with_timeout 6 hyprctl -j getoption "$opt_name" 2>/dev/null || true)
    if [[ -z "$raw" ]] || [[ "$raw" == *"no such option"* ]] || ! printf "%s" "$raw" | jq empty 2>/dev/null; then
        printf "{}"
        return 1
    fi

    printf "%s" "$raw"
    return 0
}

# Captures runtime state from Hyprland and Quickshell, returning a canonical JSON document.
# Uses a single batched IPC call first so even slow emulated environments complete in ~1.5s.
capture_snapshot() {
    local qs_strategy="${1:-sigstop}"
    local current_uid="${UID:-$(id -u)}"

    local batch_raw=""
    local parsed_batch=""
    local attempt
    for attempt in 1 2; do
        batch_raw=$(run_with_timeout 8 hyprctl -j --batch \
            "getoption animations:enabled ; getoption decoration:blur:enabled ; getoption decoration:shadow:enabled ; getoption decoration:rounding ; monitors" \
            2>/dev/null || true)
        if [[ -n "$batch_raw" ]]; then
            parsed_batch=$(printf "%s" "$batch_raw" | jq -cs 'if length == 5 and (.[4] | type == "array") then . else empty end' 2>/dev/null || true)
            if [[ -n "$parsed_batch" ]]; then
                break
            fi
        fi
        sleep 0.2
    done

    local anim_raw="{}" blur_raw="{}" shadow_raw="{}" rounding_raw="{}" monitors_raw=""
    if [[ -n "$parsed_batch" ]]; then
        anim_raw=$(printf "%s" "$parsed_batch" | jq -c '.[0]')
        blur_raw=$(printf "%s" "$parsed_batch" | jq -c '.[1]')
        shadow_raw=$(printf "%s" "$parsed_batch" | jq -c '.[2]')
        rounding_raw=$(printf "%s" "$parsed_batch" | jq -c '.[3]')
        monitors_raw=$(printf "%s" "$parsed_batch" | jq -c '.[4]')
    else
        # Fallback to individual queries if --batch failed
        for attempt in 1 2; do
            monitors_raw=$(run_with_timeout 6 hyprctl -j monitors 2>/dev/null || true)
            if [[ -n "$monitors_raw" ]] && printf "%s" "$monitors_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
                break
            fi
            monitors_raw=""
            sleep 0.2
        done

        if [[ -z "$monitors_raw" ]]; then
            if declare -F ui_log_fail >/dev/null 2>&1; then
                ui_log_fail "Unable to communicate with Hyprland via hyprctl IPC." \
                    "Ensure Hyprland is running and HYPRLAND_INSTANCE_SIGNATURE is set in this session."
            else
                echo "[ FAIL ] Unable to communicate with Hyprland via hyprctl IPC." >&2
            fi
            return 1
        fi

        anim_raw=$(_query_hypr_option_json "animations:enabled" || true)
        blur_raw=$(_query_hypr_option_json "decoration:blur:enabled" || true)
        shadow_raw=$(_query_hypr_option_json "decoration:shadow:enabled" || true)
        rounding_raw=$(_query_hypr_option_json "decoration:rounding" || true)
    fi

    # Extract exact live option values without inventing defaults on missing/false options
    local anim_json blur_json shadow_json rounding_json
    anim_json=$(printf "%s" "$anim_raw" | jq -c '
        if (type == "object") and ((.bool | type) == "boolean") then .bool
        elif (type == "object") and ((.int | type) == "number") then (.int != 0)
        else "unavailable" end
    ' 2>/dev/null || echo '"unavailable"')

    blur_json=$(printf "%s" "$blur_raw" | jq -c '
        if (type == "object") and ((.bool | type) == "boolean") then .bool
        elif (type == "object") and ((.int | type) == "number") then (.int != 0)
        else "unavailable" end
    ' 2>/dev/null || echo '"unavailable"')

    shadow_json=$(printf "%s" "$shadow_raw" | jq -c '
        if (type == "object") and ((.bool | type) == "boolean") then .bool
        elif (type == "object") and ((.int | type) == "number") then (.int != 0)
        else "unavailable" end
    ' 2>/dev/null || echo '"unavailable"')

    rounding_json=$(printf "%s" "$rounding_raw" | jq -c '
        if (type == "object") and ((.int | type) == "number") then .int
        else "unavailable" end
    ' 2>/dev/null || echo '"unavailable"')

    # Query DPMS status across active monitors
    local dpms_val
    dpms_val=$(printf "%s" "$monitors_raw" | jq -r '
        if (type == "array" and length > 0) then
            any(.[] | select(.disabled == false); .dpmsStatus == true)
        else true end
    ' 2>/dev/null || echo "true")
    [[ "$dpms_val" == "true" || "$dpms_val" == "false" ]] || dpms_val="true"

    # Discover omarchy-shell / quickshell PID scoped strictly to current user (${UID})
    local qs_pid="" was_running="false"
    qs_pid=$(pgrep -u "$current_uid" -x "omarchy-shell" 2>/dev/null | head -n 1 || true)
    if [[ -z "$qs_pid" ]]; then
        qs_pid=$(pgrep -u "$current_uid" -x "quickshell" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$qs_pid" && "$qs_pid" =~ ^[0-9]+$ ]] && (( qs_pid > 1 )); then
        was_running="true"
    else
        qs_pid="null"
        was_running="false"
    fi

    local stay_awake_was_active="false"
    if [[ -f "${HOME}/.local/state/omarchy/indicators/stay-awake" ]]; then
        stay_awake_was_active="true"
    fi

    local action_label="SIGSTOP"
    if [[ "${qs_strategy,,}" != "sigstop" ]]; then
        action_label="SIGSTOP"
    fi

    # Construct canonical JSON snapshot payload
    jq -n \
      --argjson timestamp "$(date +%s)" \
      --argjson session_uid "$current_uid" \
      --arg his "${HYPRLAND_INSTANCE_SIGNATURE:-unknown}" \
      --argjson anim "$anim_json" \
      --argjson blur "$blur_json" \
      --argjson shadow "$shadow_json" \
      --argjson rounding "$rounding_json" \
      --argjson dpms "$dpms_val" \
      --argjson qs_pid "$qs_pid" \
      --argjson qs_running "$was_running" \
      --arg qs_action "$action_label" \
      --argjson stay_awake "$stay_awake_was_active" \
      '{
        schema_version: 2,
        timestamp: $timestamp,
        session_uid: $session_uid,
        hyprland_instance_signature: $his,
        stay_awake_was_active: $stay_awake,
        compositor_properties: {
          "animations:enabled": $anim,
          "decoration:blur:enabled": $blur,
          "decoration:shadow:enabled": $shadow,
          "decoration:rounding": $rounding,
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
            (has("animations:enabled") and ((.["animations:enabled"] | type == "boolean") or (.["animations:enabled"] | type == "number") or (.["animations:enabled"] == "unavailable")))
            and (has("decoration:blur:enabled") and ((.["decoration:blur:enabled"] | type == "boolean") or (.["decoration:blur:enabled"] == "unavailable")))
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
