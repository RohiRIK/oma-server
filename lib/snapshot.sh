#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/snapshot.sh
# Snapshot extraction & validation routines for omarchy-server-mode (oma-server)
set -euo pipefail

# Captures runtime state from Hyprland and Quickshell, returning a JSON document
capture_snapshot() {
    local qs_strategy="${1:-sigstop}"

    # Verify that the Hyprland IPC socket is responsive
    if ! hyprctl -j monitors >/dev/null 2>&1; then
        echo "Error: Unable to communicate with Hyprland via hyprctl IPC." >&2
        return 1
    fi

    # 1. Query compositor properties using hyprctl -j getoption
    local anim_raw blur_raw shadow_raw vfr_raw
    anim_raw=$(hyprctl -j getoption "animations:enabled" 2>/dev/null || echo '{"int":1}')
    blur_raw=$(hyprctl -j getoption "decoration:blur:enabled" 2>/dev/null || echo '{"int":1}')
    shadow_raw=$(hyprctl -j getoption "decoration:drop_shadow" 2>/dev/null || true)
    if [[ "$shadow_raw" =~ "no such option" || -z "$shadow_raw" ]]; then
        shadow_raw=$(hyprctl -j getoption "decoration:shadow:enabled" 2>/dev/null || echo '{"int":1}')
    fi
    vfr_raw=$(hyprctl -j getoption "misc:vfr" 2>/dev/null || echo '{"int":1}')

    local anim_val blur_val shadow_val vfr_val
    anim_val=$(echo "$anim_raw" | jq -r 'if .int != null then .int elif .bool != null then (if .bool then 1 else 0 end) else 1 end')
    blur_val=$(echo "$blur_raw" | jq -r 'if .bool != null then .bool elif .int != null then (.int == 1) elif .set != null then .set else false end')
    shadow_val=$(echo "$shadow_raw" | jq -r 'if .bool != null then .bool elif .int != null then (.int == 1) elif .set != null then .set else false end')
    if [[ "$vfr_raw" =~ "no such option" ]]; then
        vfr_val=1
    else
        vfr_val=$(echo "$vfr_raw" | jq -r 'if .int != null then .int elif .bool != null then (if .bool then 1 else 0 end) else 1 end')
    fi

    # 2. Query DPMS status across active monitors via hyprctl -j monitors
    local monitors_raw dpms_val
    monitors_raw=$(hyprctl -j monitors 2>/dev/null || echo '[]')
    dpms_val=$(echo "$monitors_raw" | jq -r 'if length > 0 then any(.[]; .dpmsStatus == true) else true end')

    # 3. Discover omarchy-shell PID scoped strictly to current user (${UID})
    local qs_pid was_running
    qs_pid=$(pgrep -u "${UID}" -x "omarchy-shell" 2>/dev/null | head -n 1 || true)
    if [[ -z "$qs_pid" ]]; then
        qs_pid=$(pgrep -u "${UID}" -x "quickshell" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -n "$qs_pid" ]]; then
        was_running=true
    else
        qs_pid="null"
        was_running=false
    fi

    local action_label="SIGSTOP"
    if [[ "${qs_strategy,,}" != "sigstop" ]]; then
        action_label="${qs_strategy^^}"
    fi

    # 4. Construct canonical JSON snapshot payload
    jq -n \
      --argjson timestamp "$(date +%s)" \
      --argjson session_uid "${UID}" \
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

# Validates that a target snapshot file exists, is well-formed, and meets schema requirements
validate_snapshot() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "Error: Snapshot file '$file' does not exist." >&2
        return 1
    fi

    # Verify JSON syntax
    if ! jq empty "$file" 2>/dev/null; then
        echo "Error: Snapshot file '$file' contains invalid JSON." >&2
        return 1
    fi

    # Verify required keys and structural hierarchy
    local is_valid
    is_valid=$(jq '
      (has("timestamp") and has("session_uid") and has("hyprland_instance_signature") and has("compositor_properties") and has("quickshell_state"))
      and (.compositor_properties | has("animations:enabled") and has("decoration:blur:enabled") and has("decoration:drop_shadow") and has("misc:vfr") and has("dpms_status"))
      and (.quickshell_state | has("pid") and has("was_running") and has("action_taken"))
    ' "$file" 2>/dev/null || echo "false")

    if [[ "$is_valid" != "true" ]]; then
        echo "Error: Snapshot in '$file' does not satisfy required schema structure." >&2
        return 1
    fi

    return 0
}
