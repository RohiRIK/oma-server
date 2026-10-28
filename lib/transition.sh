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
    # The bar is the long-lived `quickshell -n -p $OMARCHY_PATH/shell` process
    # (omarchy-launch-shell). `omarchy-shell` is only Omarchy's short-lived IPC wrapper
    # script (e.g. `omarchy-shell shell ping`), never the shell itself, so it is not
    # matched; -o picks the oldest quickshell if several exist.
    qs_pid=$(pgrep -o -u "$current_uid" -x "quickshell" 2>/dev/null || true)

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

    if ! run_with_timeout 6 hyprctl -j monitors >/dev/null 2>&1; then
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
    local current_uid="${UID:-$(id -u)}"

    local raw_what raw_why what why
    raw_what="$(config_get_scalar "$config_file" "inhibit" "what" "sleep:idle:handle-lid-switch")"
    raw_why="$(config_get_scalar "$config_file" "inhibit" "why" "Omarchy Homelab Workload Active")"
    what="$(validate_inhibit_what "$raw_what")"
    why="$(sanitize_label_string "$raw_why" "Omarchy Homelab Workload Active")"

    # Clean up any stale inhibitor before spawning
    stop_inhibitor "$run_dir"

    local err_file="$run_dir/inhibitor.err"
    rm -f "$err_file"

    # Engage Omarchy's native stay-awake indicator alongside systemd-inhibit
    mkdir -p "${HOME}/.local/state/omarchy/indicators" 2>/dev/null || true
    touch "${HOME}/.local/state/omarchy/indicators/stay-awake" 2>/dev/null || true

    local in_pid=""
    local used_systemd_run="false"

    # Primary strategy: Spawn inside systemd --user manager cgroup (user@UID.service)
    # so Polkit maps the caller to the user's active graphical seat0 session even when
    # invoked over SSH, AND so SSH PTY hangup (SIGHUP) never terminates the inhibitor.
    if command -v systemd-run >/dev/null 2>&1 && (systemctl --user is-system-running >/dev/null 2>&1 || systemctl --user status >/dev/null 2>&1); then
        systemctl --user stop oma-server-inhibitor.service >/dev/null 2>&1 || true
        systemctl --user reset-failed oma-server-inhibitor.service >/dev/null 2>&1 || true
        if systemd-run --user \
            --unit=oma-server-inhibitor \
            --collect \
            --property=KillMode=control-group \
            systemd-inhibit \
                --no-ask-password \
                --what="$what" \
                --who="oma-server" \
                --why="$why" \
                --mode=block \
                sleep infinity >/dev/null 2>"$err_file"; then
            used_systemd_run="true"
        fi
    fi

    # Fallback strategy: Detached setsid session with SIGHUP ignored
    if [[ "$used_systemd_run" != "true" ]]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid -f bash -p -c "
                trap '' HUP
                { exec 200>&-; } 2>/dev/null || true
                exec systemd-inhibit \
                    --no-ask-password \
                    --what=\"\$1\" \
                    --who=\"oma-server\" \
                    --why=\"\$2\" \
                    --mode=block \
                    sleep infinity
            " _ "$what" "$why" </dev/null >/dev/null 2>"$err_file"
        else
            (
                trap '' HUP
                { exec 200>&-; } 2>/dev/null || true
                exec nohup systemd-inhibit \
                    --no-ask-password \
                    --what="$what" \
                    --who="oma-server" \
                    --why="$why" \
                    --mode=block \
                    sleep infinity
            ) </dev/null >/dev/null 2>"$err_file" &
            in_pid=$!
        fi
    fi

    # Wait ~1.0s to ensure Polkit authorization completes and does not exit asynchronously
    sleep 1.0

    if [[ "$used_systemd_run" == "true" ]]; then
        in_pid=$(systemctl --user show -p MainPID --value oma-server-inhibitor.service 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if [[ -z "$in_pid" || "$in_pid" == "0" ]]; then
        in_pid=$(pgrep -u "$current_uid" -f "systemd-inhibit.*--who=oma-server" 2>/dev/null | head -n 1 || true)
    fi

    # Verify both process liveness and registration in systemd-logind inhibitor table
    local registered="false"
    local check_iter
    for check_iter in 1 2 3; do
        if verify_pid_identity "$in_pid" "systemd-inhibit"; then
            if run_with_timeout 3 systemd-inhibit --list 2>/dev/null | grep -q "oma-server"; then
                registered="true"
                break
            fi
        else
            break
        fi
        sleep 0.2
    done

    if [[ "$registered" == "true" ]] && verify_pid_identity "$in_pid" "systemd-inhibit"; then
        printf "%s\n" "$in_pid" > "$run_dir/inhibitor.pid"
        chmod 0600 "$run_dir/inhibitor.pid"
        rm -f "$err_file"
        return 0
    fi

    local err_detail=""
    if [[ -f "$err_file" && -s "$err_file" ]]; then
        err_detail=$(head -n 1 "$err_file" | tr -d '\r\n' || true)
    elif [[ "$used_systemd_run" == "true" ]]; then
        err_detail=$(journalctl --user -u oma-server-inhibitor.service -n 3 --no-pager -o cat 2>/dev/null | tail -n 1 || true)
    fi
    rm -f "$err_file"
    systemctl --user stop oma-server-inhibitor.service >/dev/null 2>&1 || true

    echo "" >&2
    ui_log_fail "Failed to establish systemd-inhibit lock (${err_detail:-Access denied by Polkit})." \
        "Ensure an active desktop seat or add /etc/polkit-1/rules.d/49-oma-server-inhibit.rules (see README.md)."
    return 1
}

stop_inhibitor() {
    local run_dir="$1"
    local pid_file="$run_dir/inhibitor.pid"
    local current_uid="${UID:-$(id -u)}"

    if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
        local in_pid=""
        in_pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)
        if verify_pid_identity "$in_pid" "systemd-inhibit|sleep"; then
            kill -TERM "$in_pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi

    systemctl --user stop oma-server-inhibitor.service >/dev/null 2>&1 || true
    systemctl --user reset-failed oma-server-inhibitor.service >/dev/null 2>&1 || true

    # Clean up any orphaned oma-server systemd-inhibit process owned by current user
    local stray_pid=""
    while IFS= read -r stray_pid; do
        [[ -z "$stray_pid" ]] && continue
        if verify_pid_identity "$stray_pid" "systemd-inhibit"; then
            kill -TERM "$stray_pid" 2>/dev/null || true
        fi
    done < <(pgrep -u "$current_uid" -f "systemd-inhibit.*--who=oma-server" 2>/dev/null || true)

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

    if [[ "$was_running" == "true" ]] && verify_pid_identity "$qs_pid" "quickshell"; then
        # Notify the bar widget to display the Homelab icon (◆) and close any open popup
        # before Quickshell's event loop is frozen with SIGSTOP.
        if command -v omarchy-shell >/dev/null 2>&1; then
            run_with_timeout 2 omarchy-shell rohirik.oma-server prepareHomelabFreeze >/dev/null 2>&1 || true
            sleep 0.25
        fi
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

    if verify_pid_identity "$qs_pid" "quickshell"; then
        kill -CONT "$qs_pid" 2>/dev/null || true
        return 0
    fi

    # Fallback discovery scoped to UID
    local fallback_pid=""
    fallback_pid=$(pgrep -o -u "$current_uid" -x "quickshell" 2>/dev/null || true)
    if verify_pid_identity "$fallback_pid" "quickshell"; then
        kill -CONT "$fallback_pid" 2>/dev/null || true
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 5. Compositor Shader & FX Throttling (Hyprland 0.56 Lua eval + Legacy Fallback)
# -----------------------------------------------------------------------------
throttle_compositor() {
    local config_file="$1"

    local auto_wake
    auto_wake="$(config_get_bool "$config_file" "profile" "auto_wake_on_input" "true")"
    local wake_bool="true"
    [[ "$auto_wake" == "false" ]] && wake_bool="false"

    # Primary strategy: Hyprland 0.56+ Lua config engine (hyprctl eval 'hl.config(...)')
    local lua_expr="hl.config({ animations = { enabled = false }, decoration = { rounding = 0, blur = { enabled = false }, shadow = { enabled = false } }, misc = { key_press_enables_dpms = ${wake_bool}, mouse_move_enables_dpms = ${wake_bool} } })"
    local eval_out=""
    local attempt
    for attempt in 1 2; do
        eval_out=$(run_with_timeout 8 hyprctl eval "$lua_expr" 2>&1 || true)
        eval_out="${eval_out#"${eval_out%%[![:space:]]*}"}"
        eval_out="${eval_out%"${eval_out##*[![:space:]]}"}"
        if [[ "$eval_out" == "ok" ]]; then
            return 0
        fi
        # If Lua eval is supported by Hyprland but IPC timed out, retry once
        if [[ "$eval_out" != *"unknown"* && "$eval_out" != *"Invalid"* && "$eval_out" != *"legacy"* ]]; then
            sleep 0.2
            continue
        fi
        break
    done

    # Fallback strategy: Legacy Hyprland conf parser (hyprctl --batch keyword ...)
    local batch_out=""
    batch_out=$(run_with_timeout 8 hyprctl --batch \
        "keyword animations:enabled 0 ; keyword decoration:blur:enabled false ; keyword decoration:shadow:enabled false ; keyword decoration:rounding 0 ; keyword misc:key_press_enables_dpms ${wake_bool} ; keyword misc:mouse_move_enables_dpms ${wake_bool}" \
        2>&1 || true)
    if [[ -n "$batch_out" && "$batch_out" != *"non-legacy"* && "$batch_out" != *"error"* && "$batch_out" == *"ok"* ]]; then
        return 0
    fi

    echo "" >&2
    ui_log_fail "Hyprland compositor throttle failed: ${eval_out:-${batch_out:-IPC timeout}}" \
        "Verify Hyprland 0.56 Lua config or IPC socket responsiveness."
    return 1
}

restore_compositor() {
    local snapshot_file="${1:-}"

    # Restore Omarchy stay-awake state if it was not active prior to Homelab Mode
    local stay_awake_prev="false"
    if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
        stay_awake_prev=$(jq -r '.stay_awake_was_active // false' "$snapshot_file" 2>/dev/null || echo "false")
    fi
    if [[ "$stay_awake_prev" != "true" ]]; then
        rm -f "${HOME}/.local/state/omarchy/indicators/stay-awake" 2>/dev/null || true
    fi

    # If snapshot contains captured compositor properties, restore them via Lua eval first
    if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
        local c_anim c_blur c_shadow c_round
        c_anim=$(jq -r '.compositor_properties["animations:enabled"]' "$snapshot_file" 2>/dev/null || echo "true")
        c_blur=$(jq -r '.compositor_properties["decoration:blur:enabled"]' "$snapshot_file" 2>/dev/null || echo "false")
        c_shadow=$(jq -r '.compositor_properties["decoration:shadow:enabled"]' "$snapshot_file" 2>/dev/null || echo "false")
        c_round=$(jq -r '.compositor_properties["decoration:rounding"]' "$snapshot_file" 2>/dev/null || echo "0")

        [[ "$c_anim" == "1" ]] && c_anim="true"
        [[ "$c_anim" == "0" ]] && c_anim="false"
        [[ "$c_anim" == "true" || "$c_anim" == "false" ]] || c_anim="true"
        [[ "$c_blur" == "true" || "$c_blur" == "false" ]] || c_blur="false"
        [[ "$c_shadow" == "true" || "$c_shadow" == "false" ]] || c_shadow="false"
        [[ "$c_round" =~ ^[0-9]+$ ]] || c_round="0"

        local restore_lua="hl.config({ animations = { enabled = ${c_anim} }, decoration = { rounding = ${c_round}, blur = { enabled = ${c_blur} }, shadow = { enabled = ${c_shadow} } } })"
        run_with_timeout 8 hyprctl eval "$restore_lua" >/dev/null 2>&1 || true
    fi

    # Only a hard IPC failure (non-zero exit, e.g. timeout 124 or unreachable
    # socket) is reported as a failed restore; reply wording varies across
    # Hyprland versions, so it is not used as a failure signal.
    local reload_out="" reload_rc=0
    reload_out=$(run_with_timeout 8 hyprctl reload 2>&1) || reload_rc=$?
    if (( reload_rc != 0 )); then
        echo "" >&2
        ui_log_fail "Hyprland config reload failed (exit ${reload_rc}): ${reload_out:-IPC timeout}" \
            "Verify Hyprland IPC socket responsiveness, then re-run 'oma-server disable'."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 6. Display Power Management (DPMS via Hyprland 0.56 Lua + Legacy Fallback)
# -----------------------------------------------------------------------------
set_display_dpms() {
    local state="$1"
    if [[ "$state" != "on" && "$state" != "off" ]]; then
        return 1
    fi

    local lua_action="enable"
    [[ "$state" == "off" ]] && lua_action="disable"

    # Primary strategy: Hyprland 0.56+ Lua dispatcher (hl.dsp.dpms)
    local out=""
    local attempt
    for attempt in 1 2; do
        out=$(run_with_timeout 8 hyprctl dispatch "hl.dsp.dpms({ action = \"${lua_action}\" })" 2>&1 || true)
        out="${out#"${out%%[![:space:]]*}"}"
        out="${out%"${out##*[![:space:]]}"}"
        if [[ "$out" == "ok" ]]; then
            return 0
        fi
        if [[ "$out" != *"Invalid dispatcher"* && "$out" != *"unknown"* ]]; then
            sleep 0.2
            continue
        fi
        break
    done

    # Fallback strategy: Legacy Hyprland dispatcher (hyprctl dispatch dpms on/off)
    local leg_out=""
    leg_out=$(run_with_timeout 6 hyprctl dispatch dpms "$state" 2>&1 || true)
    leg_out="${leg_out#"${leg_out%%[![:space:]]*}"}"
    leg_out="${leg_out%"${leg_out##*[![:space:]]}"}"
    if [[ "$leg_out" == "ok" ]]; then
        return 0
    fi

    echo "" >&2
    ui_log_fail "Hyprland DPMS '${state}' dispatch failed: ${out:-${leg_out:-IPC timeout}}" \
        "Verify Hyprland display backend and Lua dispatcher availability."
    return 1
}

# -----------------------------------------------------------------------------
# 7. Dead Man's Switch (Auto-Revert Timeout Guard)
# -----------------------------------------------------------------------------
start_timeout_guard() {
    local run_dir="$1"
    local timeout_sec="$2"
    local self_bin="$3"
    local timeout_label="${4:-${timeout_sec}s}"
    local current_uid="${UID:-$(id -u)}"

    stop_timeout_guard "$run_dir" "false"

    if [[ -z "$timeout_sec" || "$timeout_sec" == "0" ]]; then
        return 0
    fi

    if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || (( timeout_sec < 5 )); then
        return 1
    fi

    local expire_epoch=$(( $(date +%s) + timeout_sec ))
    local timer_pid=""
    local used_systemd_run="false"

    # Primary strategy: Detached systemd --user service unit so SSH logout (SIGHUP)
    # never kills the countdown timer, and KillMode=process ensures the disable child
    # is never terminated mid-flight.
    if command -v systemd-run >/dev/null 2>&1 && (systemctl --user is-system-running >/dev/null 2>&1 || systemctl --user status >/dev/null 2>&1); then
        systemctl --user stop oma-server-timer.service >/dev/null 2>&1 || true
        systemctl --user reset-failed oma-server-timer.service >/dev/null 2>&1 || true
        if systemd-run --user \
            --unit=oma-server-timer \
            --collect \
            --property=KillMode=process \
            bash -p -c "
                trap '' HUP
                { exec 200>&-; } 2>/dev/null || true
                sleep \"\$1\"
                rm -f \"\$2/timeout.pid\" \"\$2/timeout.meta\"
                if [[ -f \"\$2/active-snapshot.json\" ]]; then
                    exec \"\$3\" disable --auto-timeout >/dev/null 2>&1
                fi
            " _ "$timeout_sec" "$run_dir" "$self_bin" >/dev/null 2>&1; then
            used_systemd_run="true"
            sleep 0.15
            timer_pid=$(systemctl --user show -p MainPID --value oma-server-timer.service 2>/dev/null | tr -d '[:space:]' || true)
        fi
    fi

    # Fallback strategy: setsid detached session with SIGHUP ignored
    if [[ "$used_systemd_run" != "true" || -z "$timer_pid" || "$timer_pid" == "0" ]]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid -f bash -p -c "
                trap '' HUP
                { exec 200>&-; } 2>/dev/null || true
                echo \$\$ > \"\$2/timeout.pid\"
                chmod 0600 \"\$2/timeout.pid\"
                sleep \"\$1\"
                rm -f \"\$2/timeout.pid\" \"\$2/timeout.meta\"
                if [[ -f \"\$2/active-snapshot.json\" ]]; then
                    exec \"\$3\" disable --auto-timeout >/dev/null 2>&1
                fi
            " _ "$timeout_sec" "$run_dir" "$self_bin" </dev/null >/dev/null 2>&1
            sleep 0.15
            if [[ -f "$run_dir/timeout.pid" ]]; then
                timer_pid=$(tr -d '[:space:]' < "$run_dir/timeout.pid" 2>/dev/null || true)
            fi
        else
            (
                trap '' HUP
                { exec 200>&-; } 2>/dev/null || true
                sleep "$timeout_sec"
                rm -f "$run_dir/timeout.pid" "$run_dir/timeout.meta"
                if [[ -f "$run_dir/active-snapshot.json" ]]; then
                    exec "$self_bin" disable --auto-timeout >/dev/null 2>&1
                fi
            ) </dev/null >/dev/null 2>&1 &
            timer_pid=$!
        fi
    fi

    if [[ -z "$timer_pid" || "$timer_pid" == "0" ]] || ! verify_pid_identity "$timer_pid" "oma-server|omarchy-server|bash|sleep"; then
        ui_log_fail "Failed to arm Dead Man's Switch background timer."
        return 1
    fi

    printf "%s\n" "$timer_pid" > "$run_dir/timeout.pid"
    printf "%s|%s\n" "$timeout_label" "$expire_epoch" > "$run_dir/timeout.meta"
    chmod 0600 "$run_dir/timeout.pid" "$run_dir/timeout.meta"
    return 0
}

stop_timeout_guard() {
    local run_dir="$1"
    local is_auto_timeout="${2:-false}"
    local timer_file="$run_dir/timeout.pid"
    local meta_file="$run_dir/timeout.meta"

    # When invoked by the Dead Man's Switch itself (--auto-timeout), NEVER kill the
    # caller process tree or stop oma-server-timer.service mid-restoration!
    if [[ "$is_auto_timeout" == "true" ]]; then
        rm -f "$timer_file" "$meta_file"
        return 0
    fi

    if [[ -f "$timer_file" && ! -L "$timer_file" ]]; then
        local timer_pid=""
        timer_pid=$(tr -d '[:space:]' < "$timer_file" 2>/dev/null || true)
        if [[ -n "$timer_pid" && "$timer_pid" =~ ^[0-9]+$ ]] && (( timer_pid != $$ && timer_pid != PPID )); then
            if verify_pid_identity "$timer_pid" "oma-server|omarchy-server|bash|sleep"; then
                pkill -TERM -P "$timer_pid" 2>/dev/null || true
                kill -TERM "$timer_pid" 2>/dev/null || true
            fi
        fi
        rm -f "$timer_file"
    fi
    rm -f "$meta_file"

    systemctl --user stop oma-server-timer.service >/dev/null 2>&1 || true
    systemctl --user reset-failed oma-server-timer.service >/dev/null 2>&1 || true
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
    set_display_dpms "on" || true
    restore_compositor "$snapshot_file" || true
    stop_timeout_guard "$run_dir" "false"
    stop_inhibitor "$run_dir"
    rm -f "$snapshot_file"
    if command -v omarchy-shell >/dev/null 2>&1; then
        run_with_timeout 2 omarchy-shell rohirik.oma-server refresh >/dev/null 2>&1 || true
    fi
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

    if ! ui_run_step 3 "$total_steps" "Throttling Hyprland compositor shaders & FX" \
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
            if ! set_display_dpms "off"; then
                return 1
            fi
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
    local is_auto_timeout="${3:-false}"

    local total_steps=5
    local -a failed_steps=()
    echo ""
    ui_log_sync "Executing transactional restoration: HOMELAB_MODE -> HOST_LAPTOP"

    # Every step still runs (best-effort restore), but each failure is recorded
    # so the caller can exit non-zero and the saved snapshot is kept for a retry.
    if ! ui_run_step 1 "$total_steps" "Resuming Quickshell event loop (SIGCONT)" \
        resume_quickshell "$snapshot_file"; then
        failed_steps+=("Resuming Quickshell event loop (SIGCONT)")
    fi

    if ! ui_run_step 2 "$total_steps" "Powering on display panels (DPMS on)" \
        set_display_dpms "on"; then
        failed_steps+=("Powering on display panels (DPMS on)")
    fi

    if ! ui_run_step 3 "$total_steps" "Reloading Hyprland compositor configuration" \
        restore_compositor "$snapshot_file"; then
        failed_steps+=("Reloading Hyprland compositor configuration")
    fi

    _release_guards() {
        stop_timeout_guard "$run_dir" "$is_auto_timeout"
        stop_inhibitor "$run_dir"
    }
    if ! ui_run_step 4 "$total_steps" "Releasing systemd-inhibit & timeout locks" \
        _release_guards; then
        failed_steps+=("Releasing systemd-inhibit & timeout locks")
    fi

    if (( ${#failed_steps[@]} > 0 )); then
        # Keep active-snapshot.json so 'disable' can be retried against the
        # original captured state; only the released guard files are purged.
        rm -f "$run_dir/inhibitor.pid" "$run_dir/inhibitor.err" "$run_dir/timeout.pid" "$run_dir/timeout.meta"
        ui_log_warn "Step 5/${total_steps} skipped: active snapshot kept because restoration is incomplete."

        echo "" >&2
        ui_log_fail "Restoration incomplete: ${#failed_steps[@]} step(s) failed." \
            "Saved state kept at ${snapshot_file}. Re-run 'oma-server disable', or 'oma-server rescue' to force a baseline."
        local step_label
        for step_label in "${failed_steps[@]}"; do
            printf "         - %s\n" "$step_label" >&2
        done

        if command -v omarchy-shell >/dev/null 2>&1; then
            run_with_timeout 2 omarchy-shell rohirik.oma-server refresh >/dev/null 2>&1 || true
        fi
        return 1
    fi

    _cleanup_session_files() {
        rm -f "$snapshot_file"
        rm -f "$run_dir/inhibitor.pid" "$run_dir/inhibitor.err" "$run_dir/timeout.pid" "$run_dir/timeout.meta"
    }
    ui_run_step 5 "$total_steps" "Purging ephemeral runtime state artifacts" \
        _cleanup_session_files

    if command -v omarchy-shell >/dev/null 2>&1; then
        run_with_timeout 2 omarchy-shell rohirik.oma-server refresh >/dev/null 2>&1 || true
    fi

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
        # Also thaw the omarchy-shell wrapper: older builds could SIGSTOP it by mistake.
        pkill -CONT -u "$current_uid" -x "omarchy-shell" 2>/dev/null || true
    }
    ui_run_step 1 "$total_steps" "Unfreezing all Quickshell processes (SIGCONT)" \
        _rescue_unfreeze

    ui_run_step 2 "$total_steps" "Forcing display outputs online (DPMS on)" \
        set_display_dpms "on" || true

    _rescue_inhibitors() {
        stop_timeout_guard "$run_dir" "false"
        stop_inhibitor "$run_dir"
    }
    ui_run_step 3 "$total_steps" "Terminating active inhibitor & timer processes" \
        _rescue_inhibitors

    ui_run_step 4 "$total_steps" "Re-synchronizing Hyprland configuration from disk" \
        restore_compositor "$snapshot_file" || true

    _rescue_purge() {
        if [[ -d "$run_dir" && ! -L "$run_dir" && -O "$run_dir" ]]; then
            rm -rf "$run_dir"
        fi
    }
    ui_run_step 5 "$total_steps" "Purging runtime directory & stale lockfiles" \
        _rescue_purge

    if command -v omarchy-shell >/dev/null 2>&1; then
        run_with_timeout 2 omarchy-shell rohirik.oma-server refresh >/dev/null 2>&1 || true
    fi

    return 0
}
