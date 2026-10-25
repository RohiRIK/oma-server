#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/transition.sh
# Transactional state mutation, PID-verified signaling, rollback recovery,
# and progress-instrumented orchestration for oma-server.
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Process Identity & Telemetry Verification (Anti-PID-Recycling Guard)
# -----------------------------------------------------------------------------
verify_pid_identity() {
    local pid="${1:-}"
    local expected_regex="${2:-.*}"

    if [[ -z "$pid" || "$pid" == "null" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]] || (( pid <= 1 )); then
        return 1
    fi

    if [[ ! -d "/proc/$pid" ]] || [[ ! -O "/proc/$pid" ]]; then
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    local comm="" cmdline=""
    comm=$(tr -d '\000\n' < "/proc/$pid/comm" 2>/dev/null || true)
    cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)

    if [[ "$comm" =~ $expected_regex ]] || [[ "$cmdline" =~ $expected_regex ]]; then
        return 0
    fi

    return 1
}

get_quickshell_telemetry() {
    local current_uid="${UID:-$(id -u)}"
    local qs_pid=""
    qs_pid=$(pgrep -u "$current_uid" -x "omarchy-shell" 2>/dev/null | head -n 1 || true)
    if [[ -z "$qs_pid" ]]; then
        qs_pid=$(pgrep -u "$current_uid" -x "quickshell" 2>/dev/null | head -n 1 || true)
    fi

    if [[ -z "$qs_pid" ]] || [[ ! -r "/proc/$qs_pid/status" ]]; then
        printf "Inactive"
        return 0
    fi

    local state_code=""
    state_code=$(awk '/^State:/ {print $2; exit}' "/proc/$qs_pid/status" 2>/dev/null || true)
    if [[ "$state_code" == "T" ]]; then
        printf "Suspended (PID: %s, SIGSTOP)" "$qs_pid"
    else
        printf "Running (PID: %s)" "$qs_pid"
    fi
}

# -----------------------------------------------------------------------------
# 2. Pre-Flight System Readiness Check
# -----------------------------------------------------------------------------
preflight_transition_check() {
    local run_dir="$1"
    local config_file="$2"

    if ! command -v systemd-inhibit >/dev/null 2>&1; then
        ui_log_fail "Pre-flight check failed: 'systemd-inhibit' binary is missing." \
            "Verify systemd package integrity."
        return 1
    fi

    if ! ensure_secure_run_dir "$run_dir"; then
        return 1
    fi

    if ! run_with_timeout 3 hyprctl -j monitors >/dev/null 2>&1; then
        ui_log_fail "Pre-flight check failed: Hyprland IPC socket is unreachable." \
            "Verify that Hyprland is active in the current desktop session."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# 3. Power & Lid Inhibit Management (systemd-inhibit)
# -----------------------------------------------------------------------------
start_inhibitor() {
    local run_dir="$1"
    local config_file="$2"

    local raw_what raw_why what why
    raw_what="$(config_get_scalar "$config_file" "inhibit" "what" "sleep:idle:handle-lid-switch")"
    raw_why="$(config_get_scalar "$config_file" "inhibit" "why" "Omarchy Homelab Workload Active")"
    what="$(validate_inhibit_what "$raw_what")"
    why="$(sanitize_label_string "$raw_why" "Omarchy Homelab Workload Active")"

    # Clean up any stale inhibitor before spawning
    stop_inhibitor "$run_dir"

    # Spawn background inhibitor with closed lock FD (200) and detached stdio
    (
        exec 200>&- 2>/dev/null || true
        exec systemd-inhibit \
            --what="$what" \
            --who="oma-server" \
            --why="$why" \
            --mode=block \
            sleep infinity
    ) </dev/null >/dev/null 2>&1 &
    local in_pid=$!

    sleep 0.1
    if verify_pid_identity "$in_pid" "systemd-inhibit|sleep"; then
        printf "%s\n" "$in_pid" > "$run_dir/inhibitor.pid"
        chmod 0600 "$run_dir/inhibitor.pid"
        return 0
    else
        ui_log_fail "Failed to establish systemd-inhibit lock process." \
            "Check 'systemctl status systemd-logind' and D-Bus user bus health."
        return 1
    fi
}

stop_inhibitor() {
    local run_dir="$1"
    local pid_file="$run_dir/inhibitor.pid"

    if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
        local in_pid=""
        in_pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)
        if verify_pid_identity "$in_pid" "systemd-inhibit|sleep"; then
            kill -TERM "$in_pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 4. Quickshell Process Lifecycle (SIGSTOP / SIGCONT)
# -----------------------------------------------------------------------------
freeze_quickshell() {
    local snapshot_file="$1"
    local qs_pid="" was_running="false"

    if [[ -f "$snapshot_file" ]]; then
        qs_pid=$(jq -r '.quickshell_state.pid' "$snapshot_file" 2>/dev/null || echo "null")
        was_running=$(jq -r '.quickshell_state.was_running' "$snapshot_file" 2>/dev/null || echo "false")
    fi

    if [[ "$was_running" == "true" ]] && verify_pid_identity "$qs_pid" "quickshell|omarchy-shell"; then
        kill -STOP "$qs_pid" 2>/dev/null || true
    fi
    return 0
}

resume_quickshell() {
    local snapshot_file="${1:-}"
    local current_uid="${UID:-$(id -u)}"
    local qs_pid="null"

    if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
        qs_pid=$(jq -r '.quickshell_state.pid' "$snapshot_file" 2>/dev/null || echo "null")
    fi

    if verify_pid_identity "$qs_pid" "quickshell|omarchy-shell"; then
        kill -CONT "$qs_pid" 2>/dev/null || true
        return 0
    fi

    # Fallback discovery scoped to UID
    local fallback_pid=""
    for proc_name in "omarchy-shell" "quickshell"; do
        fallback_pid=$(pgrep -u "$current_uid" -x "$proc_name" 2>/dev/null | head -n 1 || true)
        if verify_pid_identity "$fallback_pid" "quickshell|omarchy-shell"; then
            kill -CONT "$fallback_pid" 2>/dev/null || true
        fi
    done
    return 0
}

# -----------------------------------------------------------------------------
# 5. Compositor Shader & FX Throttling
# -----------------------------------------------------------------------------
throttle_compositor() {
    local config_file="$1"

    # Disable expensive rendering shaders and animations via batch IPC
    run_with_timeout 3 hyprctl --batch \
        "keyword animations:enabled 0 ; keyword decoration:blur:enabled false ; keyword decoration:shadow:enabled false ; keyword decoration:drop_shadow false ; keyword decoration:rounding 0 ; keyword misc:vfr 1" \
        >/dev/null 2>&1 || {
        # Fallback to individual calls if --batch is unsupported
        run_with_timeout 2 hyprctl keyword animations:enabled 0 >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword decoration:blur:enabled false >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword decoration:shadow:enabled false >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword decoration:drop_shadow false >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword decoration:rounding 0 >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword misc:vfr 1 >/dev/null 2>&1 || true
    }

    local auto_wake
    auto_wake="$(config_get_bool "$config_file" "profile" "auto_wake_on_input" "true")"
    if [[ "$auto_wake" == "true" ]]; then
        run_with_timeout 2 hyprctl keyword misc:mouse_move_enables_dpms true >/dev/null 2>&1 || true
        run_with_timeout 2 hyprctl keyword misc:key_press_enables_dpms true >/dev/null 2>&1 || true
    fi
    return 0
}

restore_compositor() {
    run_with_timeout 4 hyprctl reload >/dev/null 2>&1 || true
    return 0
}

# -----------------------------------------------------------------------------
# 6. Display Power Management (DPMS)
# -----------------------------------------------------------------------------
set_display_dpms() {
    local state="$1"
    if [[ "$state" != "on" && "$state" != "off" ]]; then
        return 1
    fi
    run_with_timeout 3 hyprctl dispatch dpms "$state" >/dev/null 2>&1 || true
    return 0
}

# -----------------------------------------------------------------------------
# 7. Dead Man's Switch (Auto-Revert Timeout Guard)
# -----------------------------------------------------------------------------
start_timeout_guard() {
    local run_dir="$1"
    local timeout_sec="$2"
    local self_bin="$3"
    local timeout_label="${4:-${timeout_sec}s}"

    stop_timeout_guard "$run_dir"

    if [[ -z "$timeout_sec" || "$timeout_sec" == "0" ]]; then
        return 0
    fi

    if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || (( timeout_sec < 5 )); then
        return 1
    fi

    local expire_epoch=$(( $(date +%s) + timeout_sec ))

    (
        exec 200>&- 2>/dev/null || true
        sleep "$timeout_sec"
        if [[ -f "$run_dir/active-snapshot.json" ]]; then
            "$self_bin" disable --auto-timeout >/dev/null 2>&1 || true
        fi
    ) </dev/null >/dev/null 2>&1 &
    local timer_pid=$!

    printf "%s\n" "$timer_pid" > "$run_dir/timeout.pid"
    printf "%s|%s\n" "$timeout_label" "$expire_epoch" > "$run_dir/timeout.meta"
    chmod 0600 "$run_dir/timeout.pid" "$run_dir/timeout.meta"
    return 0
}

stop_timeout_guard() {
    local run_dir="$1"
    local timer_file="$run_dir/timeout.pid"
    local meta_file="$run_dir/timeout.meta"

    if [[ -f "$timer_file" && ! -L "$timer_file" ]]; then
        local timer_pid=""
        timer_pid=$(tr -d '[:space:]' < "$timer_file" 2>/dev/null || true)
        if verify_pid_identity "$timer_pid" "oma-server|omarchy-server|bash|sleep"; then
            # Terminate child sleep processes first, then the subshell
            pkill -TERM -P "$timer_pid" 2>/dev/null || true
            kill -TERM "$timer_pid" 2>/dev/null || true
        fi
        rm -f "$timer_file"
    fi
    rm -f "$meta_file"
    return 0
}

# -----------------------------------------------------------------------------
# 8. Rollback & High-Level Transition Orchestrators
# -----------------------------------------------------------------------------
rollback_homelab_transition() {
    local run_dir="$1"
    local snapshot_file="$2"
    local reason="${3:-Unexpected error during transition}"

    ui_log_warn "Transition failed ($reason). Initiating automatic safety rollback..."
    resume_quickshell "$snapshot_file"
    set_display_dpms "on"
    restore_compositor
    stop_timeout_guard "$run_dir"
    stop_inhibitor "$run_dir"
    rm -f "$snapshot_file"
    ui_log_info "Rollback complete: Host desktop baseline restored safely."
}

apply_homelab_mode() {
    local run_dir="$1"
    local config_file="$2"
    local snapshot_file="$3"
    local timeout_sec="$4"
    local timeout_label="$5"
    local self_bin="$6"

    local dpms_off
    dpms_off="$(config_get_bool "$config_file" "profile" "dpms_off_on_enable" "true")"

    local total_steps=5
    echo ""
    ui_log_sync "Executing transactional transition: HOST_LAPTOP -> HOMELAB_MODE"

    if ! ui_run_step 1 "$total_steps" "Validating runtime readiness & pre-flight checks" \
        preflight_transition_check "$run_dir" "$config_file"; then
        rollback_homelab_transition "$run_dir" "$snapshot_file" "Pre-flight check failed"
        return 1
    fi

    if ! ui_run_step 2 "$total_steps" "Engaging systemd-inhibit power & lid lock" \
        start_inhibitor "$run_dir" "$config_file"; then
        rollback_homelab_transition "$run_dir" "$snapshot_file" "Inhibitor lock failed"
        return 1
    fi

    if ! ui_run_step 3 "$total_steps" "Throttling Hyprland compositor shaders & VFR" \
        throttle_compositor "$config_file"; then
        rollback_homelab_transition "$run_dir" "$snapshot_file" "Compositor throttle failed"
        return 1
    fi

    if [[ -n "$timeout_sec" && "$timeout_sec" != "0" ]]; then
        if ! ui_run_step 4 "$total_steps" "Arming Dead Man's Switch timer ($timeout_label)" \
            start_timeout_guard "$run_dir" "$timeout_sec" "$self_bin" "$timeout_label"; then
            rollback_homelab_transition "$run_dir" "$snapshot_file" "Timeout guard failed"
            return 1
        fi
    else
        ui_run_step 4 "$total_steps" "Dead Man's Switch timer bypassed (manual mode)" true
    fi

    # Final step combines DPMS powerdown and Quickshell SIGSTOP so the shell is
    # only paused after every preceding guardrail is confirmed active.
    _finalize_dpms_and_freeze() {
        if [[ "$dpms_off" == "true" ]]; then
            set_display_dpms "off"
        fi
        freeze_quickshell "$snapshot_file"
    }

    if ! ui_run_step 5 "$total_steps" "Powering down displays & suspending Quickshell" \
        _finalize_dpms_and_freeze; then
        rollback_homelab_transition "$run_dir" "$snapshot_file" "Display/Shell suspend failed"
        return 1
    fi

    return 0
}

restore_host_mode() {
    local run_dir="$1"
    local snapshot_file="$2"

    local total_steps=5
    echo ""
    ui_log_sync "Executing transactional restoration: HOMELAB_MODE -> HOST_LAPTOP"

    ui_run_step 1 "$total_steps" "Resuming Quickshell event loop (SIGCONT)" \
        resume_quickshell "$snapshot_file"

    ui_run_step 2 "$total_steps" "Powering on display panels (DPMS on)" \
        set_display_dpms "on"

    ui_run_step 3 "$total_steps" "Reloading Hyprland compositor configuration" \
        restore_compositor

    _release_guards() {
        stop_timeout_guard "$run_dir"
        stop_inhibitor "$run_dir"
    }
    ui_run_step 4 "$total_steps" "Releasing systemd-inhibit & timeout locks" \
        _release_guards

    _cleanup_session_files() {
        rm -f "$snapshot_file"
        rm -f "$run_dir/inhibitor.pid" "$run_dir/timeout.pid" "$run_dir/timeout.meta"
    }
    ui_run_step 5 "$total_steps" "Purging ephemeral runtime state artifacts" \
        _cleanup_session_files

    return 0
}

force_rescue_mode() {
    local run_dir="$1"
    local snapshot_file="$2"
    local current_uid="${UID:-$(id -u)}"

    local total_steps=5
    echo ""
    ui_log_warn "Executing Emergency Rescue Recovery sequence..."

    _rescue_unfreeze() {
        resume_quickshell "$snapshot_file"
        pkill -CONT -u "$current_uid" -x "quickshell" 2>/dev/null || true
        pkill -CONT -u "$current_uid" -x "omarchy-shell" 2>/dev/null || true
    }
    ui_run_step 1 "$total_steps" "Unfreezing all Quickshell processes (SIGCONT)" \
        _rescue_unfreeze

    ui_run_step 2 "$total_steps" "Forcing display outputs online (DPMS on)" \
        set_display_dpms "on"

    _rescue_inhibitors() {
        stop_timeout_guard "$run_dir"
        stop_inhibitor "$run_dir"
    }
    ui_run_step 3 "$total_steps" "Terminating active inhibitor & timer processes" \
        _rescue_inhibitors

    ui_run_step 4 "$total_steps" "Re-synchronizing Hyprland configuration from disk" \
        restore_compositor

    _rescue_purge() {
        if [[ -d "$run_dir" && ! -L "$run_dir" && -O "$run_dir" ]]; then
            rm -rf "$run_dir"
        fi
    }
    ui_run_step 5 "$total_steps" "Purging runtime directory & stale lockfiles" \
        _rescue_purge

    return 0
}
