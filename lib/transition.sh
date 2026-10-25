#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/transition.sh
# State mutation and restoration routines for oma-server (Phase 2, 3 & 4)
set -euo pipefail

# 1. Power & Lid Inhibit Management (systemd-inhibit)
start_inhibitor() {
    local run_dir="$1"
    local config_file="$2"

    local what="sleep:idle:handle-lid-switch"
    local why="Omarchy Homelab Workload Active"

    if [[ -f "$config_file" ]]; then
        local cfg_what cfg_why
        cfg_what=$(grep -E '^\s*what\s*=' "$config_file" | head -n 1 | cut -d'"' -f2 || true)
        cfg_why=$(grep -E '^\s*why\s*=' "$config_file" | head -n 1 | cut -d'"' -f2 || true)
        [[ -n "$cfg_what" ]] && what="$cfg_what"
        [[ -n "$cfg_why" ]] && why="$cfg_why"
    fi

    # Spawn background inhibitor holding lock
    systemd-inhibit \
        --what="$what" \
        --who="oma-server" \
        --why="$why" \
        --mode=block \
        sleep infinity >/dev/null 2>&1 &
    local in_pid=$!

    # Verify process started
    sleep 0.1
    if kill -0 "$in_pid" 2>/dev/null; then
        echo "$in_pid" > "$run_dir/inhibitor.pid"
        chmod 600 "$run_dir/inhibitor.pid"
        return 0
    else
        echo "Error: Failed to spawn systemd-inhibit process." >&2
        return 1
    fi
}

stop_inhibitor() {
    local run_dir="$1"
    local pid_file="$run_dir/inhibitor.pid"

    if [[ -f "$pid_file" ]]; then
        local in_pid
        in_pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$in_pid" ]] && kill -0 "$in_pid" 2>/dev/null; then
            kill -TERM "$in_pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
}

# 2. Quickshell Process Lifecycle (SIGSTOP / SIGCONT)
freeze_quickshell() {
    local snapshot_file="$1"

    local qs_pid was_running
    qs_pid=$(jq -r '.quickshell_state.pid' "$snapshot_file" 2>/dev/null || echo "null")
    was_running=$(jq -r '.quickshell_state.was_running' "$snapshot_file" 2>/dev/null || echo "false")

    if [[ "$was_running" == "true" && "$qs_pid" != "null" && -n "$qs_pid" ]]; then
        if kill -0 "$qs_pid" 2>/dev/null; then
            kill -STOP "$qs_pid" 2>/dev/null || true
        fi
    fi
}

resume_quickshell() {
    local snapshot_file="$1"

    local qs_pid
    if [[ -f "$snapshot_file" ]]; then
        qs_pid=$(jq -r '.quickshell_state.pid' "$snapshot_file" 2>/dev/null || echo "null")
    else
        qs_pid="null"
    fi

    if [[ "$qs_pid" != "null" && -n "$qs_pid" ]]; then
        if kill -0 "$qs_pid" 2>/dev/null; then
            kill -CONT "$qs_pid" 2>/dev/null || true
            return 0
        fi
    fi

    # Fallback discovery if snapshot PID expired or was invalid
    local fallback_pid
    fallback_pid=$(pgrep -u "${UID}" -x "quickshell" 2>/dev/null | head -n 1 || true)
    if [[ -n "$fallback_pid" ]] && kill -0 "$fallback_pid" 2>/dev/null; then
        kill -CONT "$fallback_pid" 2>/dev/null || true
    fi
}

# 3. Compositor Shader & FX Throttling
throttle_compositor() {
    local config_file="$1"

    # Disable expensive rendering loops
    hyprctl keyword animations:enabled 0 >/dev/null 2>&1 || true
    hyprctl keyword decoration:blur:enabled false >/dev/null 2>&1 || true
    hyprctl keyword decoration:shadow:enabled false >/dev/null 2>&1 || true
    hyprctl keyword decoration:drop_shadow false >/dev/null 2>&1 || true
    hyprctl keyword decoration:rounding 0 >/dev/null 2>&1 || true
    hyprctl keyword misc:vfr 1 >/dev/null 2>&1 || true

    # Phase 4 Input Guard: touching keyboard/mouse can wake the screen
    local auto_wake="true"
    if [[ -f "$config_file" ]]; then
        local cfg_wake
        cfg_wake=$(grep -E '^\s*auto_wake_on_input\s*=' "$config_file" | head -n 1 | awk '{print $3}' || true)
        [[ "$cfg_wake" == "false" ]] && auto_wake="false"
    fi

    if [[ "$auto_wake" == "true" ]]; then
        hyprctl keyword misc:mouse_move_enables_dpms true >/dev/null 2>&1 || true
        hyprctl keyword misc:key_press_enables_dpms true >/dev/null 2>&1 || true
    fi
}

restore_compositor() {
    # Omarchy canonical pattern: reload user config to restore exact look and feel
    hyprctl reload >/dev/null 2>&1 || true
}

# 4. Display Power Management
set_display_dpms() {
    local state="$1" # "on" or "off"
    hyprctl dispatch dpms "$state" >/dev/null 2>&1 || true
}

# 5. Dead Man's Switch (Timeout Guard)
start_timeout_guard() {
    local run_dir="$1"
    local timeout_val="$2"
    local self_bin="$3"

    [[ -z "$timeout_val" || "$timeout_val" == "0" ]] && return 0

    # Launch background sleep timer
    (
        sleep "$timeout_val"
        if [[ -f "$run_dir/active-snapshot.json" ]]; then
            "$self_bin" disable --auto-timeout >/dev/null 2>&1 || true
        fi
    ) >/dev/null 2>&1 &
    local timer_pid=$!

    echo "$timer_pid" > "$run_dir/timeout.pid"
    chmod 600 "$run_dir/timeout.pid"
}

stop_timeout_guard() {
    local run_dir="$1"
    local timer_file="$run_dir/timeout.pid"

    if [[ -f "$timer_file" ]]; then
        local timer_pid
        timer_pid=$(cat "$timer_file" 2>/dev/null || true)
        if [[ -n "$timer_pid" ]] && kill -0 "$timer_pid" 2>/dev/null; then
            kill -TERM "$timer_pid" 2>/dev/null || true
        fi
        rm -f "$timer_file"
    fi
}

# 6. High-Level Transition Orchestrators
apply_homelab_mode() {
    local run_dir="$1"
    local config_file="$2"
    local snapshot_file="$3"
    local timeout_val="$4"
    local self_bin="$5"

    echo "==> Engaging systemd-inhibit power lock..."
    start_inhibitor "$run_dir" "$config_file"

    echo "==> Throttling Hyprland compositor shaders and animations..."
    throttle_compositor "$config_file"

    echo "==> Freezing Quickshell event loop (SIGSTOP)..."
    freeze_quickshell "$snapshot_file"

    # Check DPMS preference
    local dpms_off="true"
    if [[ -f "$config_file" ]]; then
        local cfg_dpms
        cfg_dpms=$(grep -E '^\s*dpms_off_on_enable\s*=' "$config_file" | head -n 1 | awk '{print $3}' || true)
        [[ "$cfg_dpms" == "false" ]] && dpms_off="false"
    fi

    if [[ "$dpms_off" == "true" ]]; then
        echo "==> Powering down display panels (DPMS off)..."
        set_display_dpms "off"
    fi

    if [[ -n "$timeout_val" && "$timeout_val" != "0" ]]; then
        echo "==> Dead man's switch timer scheduled: $timeout_val"
        start_timeout_guard "$run_dir" "$timeout_val" "$self_bin"
    fi
}

restore_host_mode() {
    local run_dir="$1"
    local snapshot_file="$2"

    echo "==> Stopping timeout guards..."
    stop_timeout_guard "$run_dir"

    echo "==> Releasing systemd-inhibit power lock..."
    stop_inhibitor "$run_dir"

    echo "==> Powering on displays (DPMS on)..."
    set_display_dpms "on"

    echo "==> Resuming Quickshell event loop (SIGCONT)..."
    resume_quickshell "$snapshot_file"

    echo "==> Restoring Hyprland look & feel settings..."
    restore_compositor

    echo "==> Cleaning session runtime state..."
    rm -f "$snapshot_file"
    rm -f "$run_dir/inhibitor.pid"
    rm -f "$run_dir/timeout.pid"
}

force_rescue_mode() {
    local run_dir="$1"
    local snapshot_file="$2"

    echo "==> [RESCUE] Releasing all inhibitor processes..."
    stop_inhibitor "$run_dir"
    stop_timeout_guard "$run_dir"

    echo "==> [RESCUE] Powering on all display outputs..."
    set_display_dpms "on"

    echo "==> [RESCUE] Resuming any suspended Quickshell processes..."
    # Resume by snapshot if present
    resume_quickshell "$snapshot_file"
    # Direct broadcast resume to any paused quickshell under UID
    pkill -CONT -u "${UID}" -x "quickshell" 2>/dev/null || true
    pkill -CONT -u "${UID}" -x "omarchy-shell" 2>/dev/null || true

    echo "==> [RESCUE] Reloading Hyprland configuration from disk..."
    restore_compositor

    echo "==> [RESCUE] Purging all runtime lockfiles..."
    rm -rf "$run_dir"
}
