#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/deep.sh
# Opt-in Deep Server Mode (DEEP_SERVER): stop the uwsm/Hyprland session and the
# display manager so the machine runs headless, then bring the desktop back
# through SDDM autologin. See README "Deep Server Mode" and the PR design notes.
#
# Root actions go only through the fixed-verb helper installed by
# `oma-server deep-setup` (/usr/local/lib/oma-server/deep-helper) and its
# exact-argument %wheel NOPASSWD sudoers grant. Nothing here is enabled by the
# default install.
set -euo pipefail

# OMA_SERVER_TEST_ROOT only relocates where root files are looked up/installed
# (sandboxed tests). The sudoers content always names the real helper path, so a
# relocated helper is never covered by the grant.
DEEP_ROOT_PREFIX="${OMA_SERVER_TEST_ROOT:-}"
DEEP_HELPER_REAL_PATH="/usr/local/lib/oma-server/deep-helper"
DEEP_HELPER_PATH="${DEEP_ROOT_PREFIX}${DEEP_HELPER_REAL_PATH}"
DEEP_HELPER_DIR="${DEEP_HELPER_PATH%/*}"
DEEP_SUDOERS_PATH="${DEEP_ROOT_PREFIX}/etc/sudoers.d/oma-server-deep"
DEEP_AUTOLOGIN_CONF="${DEEP_ROOT_PREFIX}/etc/sddm.conf.d/autologin.conf"
DEEP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oma-server"
DEEP_STATE_FILE="$DEEP_STATE_DIR/deep.json"
DEEP_LAST_FILE="$DEEP_STATE_DIR/last-deep.json"
DEEP_LOG_FILE="$DEEP_STATE_DIR/deep.log"
DEEP_LOCK_FILE="$DEEP_STATE_DIR/deep.lock"
DEEP_SESSION_UNIT="wayland-wm@hyprland.desktop.service"
DEEP_TRANSITION_UNIT="oma-server-deep-transition"
DEEP_USER_TIMER_UNIT="oma-server-timer"
DEEP_POLL="${OMA_DEEP_POLL_INTERVAL:-1}"
DEEP_PANIC_HINT="sudo systemctl start display-manager"

# -----------------------------------------------------------------------------
# 1. State file (XDG state dir, not /run/user: survives the user manager)
# -----------------------------------------------------------------------------
deep_state_dir_ensure() {
    if [[ -L "$DEEP_STATE_DIR" ]]; then
        ui_log_fail "Security violation: '$DEEP_STATE_DIR' is a symbolic link."
        return 1
    fi
    mkdir -p "$DEEP_STATE_DIR"
    chmod 0700 "$DEEP_STATE_DIR"
    [[ -O "$DEEP_STATE_DIR" ]] || { ui_log_fail "'$DEEP_STATE_DIR' is not owned by the current user."; return 1; }
}

deep_boot_id() {
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown"
}

deep_state_exists() {
    [[ -f "$DEEP_STATE_FILE" && ! -L "$DEEP_STATE_FILE" ]]
}

deep_state_read() {
    deep_state_exists || return 1
    jq -e 'type == "object" and has("state")' "$DEEP_STATE_FILE" >/dev/null 2>&1 || return 1
    cat "$DEEP_STATE_FILE"
}

deep_state_get() {
    local key="$1" default_val="${2:-}"
    local val
    val=$(jq -r --arg k "$key" '.[$k] // empty | if type == "array" or type == "object" then tojson else tostring end' \
        "$DEEP_STATE_FILE" 2>/dev/null || true)
    printf "%s" "${val:-$default_val}"
}

# Atomic write: temp file in the same dir, validate, rename.
deep_state_write() {
    local json="$1"
    deep_state_dir_ensure || return 1
    local tmp
    tmp=$(mktemp "$DEEP_STATE_DIR/.deep.json.XXXXXX")
    if ! printf "%s\n" "$json" | jq -e 'if type == "object" and has("state") then . else error("invalid deep state") end' > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        ui_log_fail "Refusing to write invalid deep state JSON."
        return 1
    fi
    chmod 0600 "$tmp"
    mv -f "$tmp" "$DEEP_STATE_FILE"
}

# deep_state_set <key> <json-value>
deep_state_set() {
    local key="$1" value="$2" cur
    cur=$(deep_state_read) || return 1
    deep_state_write "$(printf "%s" "$cur" | jq -c --arg k "$key" --argjson v "$value" '.[$k] = $v')"
}

deep_log() {
    local msg="$1"
    deep_state_dir_ensure >/dev/null 2>&1 || true
    printf "%s %s\n" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >> "$DEEP_LOG_FILE" 2>/dev/null || true
}

deep_write_last() {
    # deep_write_last <result> <reason>
    local result="$1" reason="${2:-}"
    local entered="" ram_before="" ram_after=""
    if deep_state_exists; then
        entered=$(deep_state_get entered_at "")
        ram_before=$(deep_state_get ram_before_mb "")
        ram_after=$(deep_state_get ram_after_mb "")
    fi
    local now; now=$(date +%s)
    local tmp; tmp=$(mktemp "$DEEP_STATE_DIR/.last-deep.json.XXXXXX")
    jq -n -c --arg result "$result" --arg reason "$reason" --arg entered "$entered" \
        --arg exited "$now" --arg rb "$ram_before" --arg ra "$ram_after" '{
            result: $result,
            reason: (if $reason == "" then null else $reason end),
            entered_at: (if $entered == "" then null else ($entered | tonumber) end),
            exited_at: ($exited | tonumber),
            duration_seconds: (if $entered == "" then null else (($exited | tonumber) - ($entered | tonumber)) end),
            freed_mb: (if $rb == "" or $ra == "" then null else (($ra | tonumber) - ($rb | tonumber)) end)
        }' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$DEEP_LAST_FILE"
}

deep_lock_held() {
    [[ -f "$DEEP_LOCK_FILE" ]] || return 1
    ! flock -n "$DEEP_LOCK_FILE" true 2>/dev/null
}

deep_available_mb() {
    awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo ""
}

# -----------------------------------------------------------------------------
# 2. Root helper access
# -----------------------------------------------------------------------------
deep_helper_installed() {
    [[ -f "$DEEP_HELPER_PATH" && ! -L "$DEEP_HELPER_PATH" && -x "$DEEP_HELPER_PATH" ]] || return 1
    [[ -f "$DEEP_SUDOERS_PATH" && ! -L "$DEEP_SUDOERS_PATH" ]] || return 1
    # Real installs must be root-owned; sandboxed tests (OMA_SERVER_TEST_ROOT) run as the user.
    local want_uid=0
    [[ -n "$DEEP_ROOT_PREFIX" ]] && want_uid="$(id -u)"
    [[ "$(stat -c %u "$DEEP_HELPER_PATH" 2>/dev/null)" == "$want_uid" ]] || return 1
    [[ "$(stat -c %u "$DEEP_HELPER_DIR" 2>/dev/null)" == "$want_uid" ]] || return 1
    return 0
}

# Omarchy-style probe (bin/omarchy-dns): lists the grant, runs and prompts nothing.
deep_grant_ok() {
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n -l -l "$DEEP_HELPER_PATH" check 2>/dev/null | grep -q '!authenticate'
}

# Non-interactive helper call (worker, timers): grant or nothing.
deep_helper() {
    sudo -n "$DEEP_HELPER_PATH" "$@"
}

deep_is_ssh() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

# pkexec only works with Omarchy's polkit agent, which lives in the running
# Quickshell bar: live GUI, not SSH, HOST_LAPTOP only (not HOMELAB: the bar is
# SIGSTOPped; not DEEP: there is no bar).
deep_pkexec_allowed() {
    [[ -n "${WAYLAND_DISPLAY:-}" ]] || return 1
    deep_is_ssh && return 1
    [[ -n "${SNAPSHOT_FILE:-}" && -f "${SNAPSHOT_FILE}" ]] && return 1
    deep_state_exists && return 1
    command -v pkexec >/dev/null 2>&1 || return 1
    return 0
}

# require_root ladder (bin/omarchy-dns): root -> TTY sudo -> sudo -n (grant) ->
# pkexec (GUI laptop only) -> fail fast, never hang on an invisible prompt.
deep_helper_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$DEEP_HELPER_PATH" "$@"
    elif [[ -t 0 ]]; then
        sudo "$DEEP_HELPER_PATH" "$@"
    elif deep_grant_ok; then
        sudo -n "$DEEP_HELPER_PATH" "$@"
    elif deep_pkexec_allowed; then
        pkexec "$DEEP_HELPER_PATH" "$@"
    else
        ui_log_fail "No non-interactive way to run the deep-mode helper (no sudo grant, no TTY)." \
            "Run 'ssh -t <host> oma-server disable', or '${DEEP_PANIC_HINT}'."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# 3. Session inspection
# -----------------------------------------------------------------------------
deep_session_active() {
    systemctl --user is-active --quiet "$DEEP_SESSION_UNIT" 2>/dev/null
}

deep_dm_active() {
    systemctl is-active --quiet display-manager.service 2>/dev/null
}

# Prints "class<TAB>title<TAB>pid" per open window. Fails if Hyprland is unreachable.
deep_list_gui_clients() {
    local out
    out=$(run_with_timeout 5 hyprctl clients -j 2>/dev/null) || return 1
    printf "%s" "$out" | jq -r 'if type == "array" then .[] | "\(.class)\t\(.title)\t\(.pid)" else empty end' 2>/dev/null
}

# Non-GUI processes in app-*.scope cgroups (tmux, agents, ...) die with the session.
deep_list_session_bound_procs() {
    local gui_pids="${1:-}"
    local uid="${UID:-$(id -u)}"
    local base="${OMA_SERVER_TEST_CGROUP_ROOT:-/sys/fs/cgroup}/user.slice/user-${uid}.slice/user@${uid}.service/app.slice"
    [[ -d "$base" ]] || return 0
    local procs pid comm
    for procs in "$base"/app-*.scope/cgroup.procs; do
        [[ -r "$procs" ]] || continue
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            [[ " $gui_pids " == *" $pid "* ]] && continue
            comm=$(tr -d '\000\n' < "/proc/$pid/comm" 2>/dev/null || true)
            [[ -n "$comm" ]] && printf "%s\t%s\n" "$pid" "$comm"
        done < "$procs"
    done | head -n 20
}

deep_on_battery() {
    local s
    for s in /sys/class/power_supply/*/status; do
        [[ -r "$s" ]] && [[ "$(cat "$s" 2>/dev/null)" == "Discharging" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# 4. Preflight (refuses on any failure; changes nothing)
# -----------------------------------------------------------------------------
deep_preflight() {
    local config_file="$1"
    local ok=0

    if [[ "$(config_get_bool "$config_file" "deep" "allowed" "false")" != "true" ]]; then
        ui_log_fail "Deep Server Mode is not set up ([deep] allowed = false)." "Run 'oma-server deep-setup' first."
        return 1
    fi
    if ! deep_helper_installed || ! deep_grant_ok; then
        ui_log_fail "Deep-mode root helper or its sudo grant is missing." "Run 'oma-server deep-setup'."
        return 1
    fi
    if [[ -n "${SNAPSHOT_FILE:-}" && -f "$SNAPSHOT_FILE" ]]; then
        ui_log_fail "HOMELAB_MODE is active; switching straight to DEEP_SERVER is refused." "Run 'oma-server disable' first."
        return 1
    fi
    if deep_state_exists; then
        ui_log_fail "Deep Server state already exists ($(deep_state_get state UNKNOWN))." "Run 'oma-server disable'."
        return 1
    fi
    local bin
    for bin in uwsm loginctl systemd-run systemd-inhibit hyprctl; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            ui_log_fail "Required binary '$bin' not found."
            ok=1
        fi
    done
    (( ok == 0 )) || return 1
    if ! deep_session_active; then
        ui_log_fail "No uwsm-managed Hyprland session ($DEEP_SESSION_UNIT is not active)." \
            "Deep Server Mode only supports Omarchy's uwsm session."
        return 1
    fi
    if [[ "$(config_get_bool "$config_file" "deep" "require_ssh" "true")" == "true" ]] && \
       ! systemctl is-active --quiet sshd.service 2>/dev/null; then
        ui_log_fail "sshd.service is not active; refusing to remove the desktop with no remote way back." \
            "Enable sshd, or set [deep] require_ssh = false if you accept the lockout risk."
        return 1
    fi
    local unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        if systemctl is-failed --quiet "$unit" 2>/dev/null; then
            ui_log_fail "Protected service '$unit' is in a failed state." "Fix it before entering Deep Server Mode."
            return 1
        fi
    done < <(get_whitelist_services "$config_file")
    return 0
}

# -----------------------------------------------------------------------------
# 5. Enter (foreground part)
# -----------------------------------------------------------------------------
# deep_enter_transaction <config> <close_apps:true|false> <timeout_seconds> <timeout_label> <self_bin>
# Exit codes: 0 entered, 1 failed/rolled back, 3 refused because of open windows.
deep_enter_transaction() {
    local config_file="$1" close_apps="$2" timeout_sec="$3" timeout_label="$4" self_bin="$5"

    deep_preflight "$config_file" || return 1

    local clients=""
    if ! clients=$(deep_list_gui_clients); then
        ui_log_fail "Could not list Hyprland windows (hyprctl clients -j failed)." "Refusing: cannot verify no unsaved work."
        return 1
    fi
    local gui_pids=""
    if [[ -n "$clients" ]]; then
        local n; n=$(printf "%s\n" "$clients" | grep -c .)
        ui_log_warn "${n} open window(s) would be closed (unsaved work is lost, windows are NOT restored):"
        printf "%s\n" "$clients" | awk -F'\t' '{printf "         - %s: %s (pid %s)\n", $1, $2, $3}' >&2
        gui_pids=$(printf "%s\n" "$clients" | awk -F'\t' '{printf "%s ", $3}')
        if [[ "$close_apps" != "true" ]]; then
            ui_log_fail "Refusing to enter Deep Server Mode while windows are open." \
                "Close them yourself, or re-run with --close-apps in a terminal and type 'yes'."
            return 3
        fi
        if [[ ! -t 0 ]]; then
            ui_log_fail "--close-apps needs an interactive terminal to type 'yes' (stdin is not a TTY)." \
                "Use 'ssh -t' or run it from a terminal."
            return 3
        fi
        local answer=""
        printf "%s Type 'yes' to close these windows and enter DEEP_SERVER: " "$(ui_badge_warn)"
        read -r answer || answer=""
        if [[ "$answer" != "yes" ]]; then
            ui_log_info "Not confirmed (expected the word 'yes'). Nothing was changed."
            return 3
        fi
    fi

    local bound
    bound=$(deep_list_session_bound_procs "$gui_pids" || true)
    if [[ -n "$bound" ]]; then
        ui_log_warn "These session-bound processes will also stop (move agents to 'systemd-run --user' units or tmux started that way):"
        printf "%s\n" "$bound" | awk -F'\t' '{printf "         - %s (pid %s)\n", $2, $1}' >&2
    fi

    if (( timeout_sec == 0 )); then
        ui_log_warn "No --timeout: nothing will bring the desktop back on its own." \
            "Ways back: SSH 'oma-server disable'; Ctrl+Alt+F2 at the machine; reboot; or '${DEEP_PANIC_HINT}'."
        if deep_on_battery; then
            ui_log_warn "On battery: the sleep/lid inhibitor keeps the machine awake indefinitely (heat, drain)."
        fi
        if [[ -t 0 ]]; then
            printf "%s Press Enter to continue, Ctrl+C to abort: " "$(ui_badge_info)"
            read -r _ || true
        fi
    fi
    ui_log_info "Panic command (from any TTY/SSH): ${DEEP_PANIC_HINT}"

    local closed_json timeout_epoch="null"
    closed_json=$(printf "%s" "$clients" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {class: .[0], title: .[1], pid: .[2]})')
    (( timeout_sec > 0 )) && timeout_epoch=$(( $(date +%s) + timeout_sec ))

    deep_state_dir_ensure || return 1
    : > "$DEEP_LOG_FILE"
    chmod 0600 "$DEEP_LOG_FILE"
    deep_state_write "$(jq -n -c \
        --arg boot "$(deep_boot_id)" \
        --argjson entered "$(date +%s)" \
        --argjson tepoch "$timeout_epoch" \
        --argjson tsec "$timeout_sec" \
        --arg tlabel "$timeout_label" \
        --argjson closed "$closed_json" \
        --arg ram "$(deep_available_mb)" '{
            state: "DEEP_ENTERING", entered_at: $entered, boot_id: $boot,
            timeout_epoch: $tepoch, timeout_seconds: $tsec, timeout_label: $tlabel,
            closed_clients: $closed, linger_was: null, dm_stopped: false,
            inhibitor_unit: "oma-server-deep-inhibit.service",
            transition_unit: "oma-server-deep-transition.service",
            ram_before_mb: (if $ram == "" then null else ($ram | tonumber) end)
        }')" || return 1

    # Detach the rest: a terminal inside Hyprland dies when the session stops.
    local -a setenv=()
    local var
    for var in HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY OMARCHY_PATH XDG_STATE_HOME XDG_CONFIG_HOME \
               OMA_SERVER_TEST_ROOT OMA_DEEP_POLL_INTERVAL; do
        [[ -n "${!var:-}" ]] && setenv+=("--setenv=${var}=${!var}")
    done
    systemctl --user reset-failed "${DEEP_TRANSITION_UNIT}.service" >/dev/null 2>&1 || true
    if ! systemd-run --user --unit="$DEEP_TRANSITION_UNIT" --collect --quiet "${setenv[@]}" \
            "$self_bin" __deep-enter-worker >/dev/null 2>&1; then
        rm -f "$DEEP_STATE_FILE"
        ui_log_fail "Could not start the detached deep-mode transition (systemd-run --user failed)." "Nothing was changed."
        return 1
    fi

    deep_follow_enter
}

# Tails deep.log until the worker reaches DEEP_SERVER or rolls back.
deep_follow_enter() {
    local follow_max="${OMA_DEEP_FOLLOW_SECONDS:-180}"
    local deadline=$(( $(date +%s) + follow_max ))
    local printed=0 total line state
    while :; do
        if [[ -f "$DEEP_LOG_FILE" ]]; then
            total=$(wc -l < "$DEEP_LOG_FILE")
            if (( total > printed )); then
                while IFS= read -r line; do
                    printf "  %s %s\n" "$(ui_badge_sync)" "${line#* }"
                done < <(tail -n +"$(( printed + 1 ))" "$DEEP_LOG_FILE" | head -n "$(( total - printed ))")
                printed=$total
            fi
        fi
        if ! deep_state_exists; then
            local reason=""
            reason=$(jq -r '.reason // ""' "$DEEP_LAST_FILE" 2>/dev/null || true)
            ui_log_fail "Deep Server Mode was not entered; changes were rolled back${reason:+: $reason}."
            return 1
        fi
        state=$(deep_state_get state "")
        case "$state" in
            DEEP_SERVER)
                ui_log_ok "DEEP_SERVER active. Desktop is stopped; run 'oma-server disable' to bring it back."
                return 0
                ;;
            DEEP_DEGRADED)
                ui_log_fail "Deep transition failed and the desktop did not come back (DEEP_DEGRADED)." \
                    "Run 'oma-server disable' again, or '${DEEP_PANIC_HINT}'."
                return 1
                ;;
        esac
        if (( $(date +%s) >= deadline )); then
            ui_log_warn "Transition still running in the background (state: ${state})." "Follow it with: tail -f ${DEEP_LOG_FILE}"
            return 4
        fi
        sleep "$DEEP_POLL"
    done
}

# -----------------------------------------------------------------------------
# 6. Enter (detached worker) and rollback
# -----------------------------------------------------------------------------
deep_wait_until() {
    # deep_wait_until <seconds> <command...>: polls until the command succeeds.
    local secs="$1"; shift
    local deadline=$(( $(date +%s) + secs ))
    while :; do
        "$@" && return 0
        (( $(date +%s) >= deadline )) && return 1
        sleep "$DEEP_POLL"
    done
}

_deep_session_down() {
    ! systemctl --user is-active --quiet "$DEEP_SESSION_UNIT" 2>/dev/null && \
    ! systemctl --user is-active --quiet graphical-session.target 2>/dev/null
}

_deep_no_clients() {
    local c
    c=$(deep_list_gui_clients 2>/dev/null) || return 1
    [[ -z "$c" ]]
}

_deep_dm_inactive() {
    ! deep_dm_active
}

_deep_inhibitor_listed() {
    run_with_timeout 3 systemd-inhibit --list 2>/dev/null | grep -q "oma-server"
}

deep_restore_linger() {
    if [[ "$(deep_state_get linger_was "")" == "no" ]]; then
        if loginctl disable-linger "${USER:-$(id -un)}" >/dev/null 2>&1; then
            deep_log "linger restored (disabled)"
        else
            deep_log "WARN could not disable linger"
        fi
    fi
}

# Undo steps 3-5 (best-effort, every undo recorded). The session is untouched.
deep_rollback() {
    local reason="$1"
    deep_log "ROLLBACK: ${reason}"
    systemctl --user stop "${DEEP_USER_TIMER_UNIT}.timer" >/dev/null 2>&1 || true
    if [[ "$(deep_state_get timeout_seconds 0)" != "0" ]]; then
        deep_helper revert-disarm >/dev/null 2>&1 || deep_log "WARN revert-disarm failed"
    fi
    deep_helper inhibit-stop >/dev/null 2>&1 || deep_log "WARN inhibit-stop failed"
    deep_restore_linger
    deep_write_last "rolled_back" "$reason"
    rm -f "$DEEP_STATE_FILE"
    deep_log "rollback complete; still in HOST_LAPTOP"
}

deep_enter_worker() {
    local config_file="$1" self_bin="$2"
    deep_state_read >/dev/null || { deep_log "worker: no deep state"; return 1; }
    [[ "$(deep_state_get state "")" == "DEEP_ENTERING" ]] || { deep_log "worker: state is not DEEP_ENTERING"; return 1; }

    exec 201>"$DEEP_LOCK_FILE"
    flock -n 201 || { deep_log "worker: deep lock busy"; return 1; }

    local user_name="${USER:-$(id -un)}"

    # Step 3: linger keeps the user manager (timers, user services) alive without a session.
    deep_log "step 3/8: ensuring linger for ${user_name}"
    local linger
    linger=$(loginctl show-user "$user_name" -p Linger --value 2>/dev/null || echo "unknown")
    if [[ "$linger" == "yes" ]]; then
        deep_state_set linger_was '"yes"'
    else
        if ! loginctl enable-linger "$user_name" >/dev/null 2>&1; then
            deep_rollback "loginctl enable-linger failed"
            return 1
        fi
        deep_state_set linger_was '"no"'
    fi

    # Step 4: root sleep/lid inhibitor (a user inhibitor cannot block lid-switch without a seat).
    deep_log "step 4/8: starting root sleep/lid inhibitor"
    if ! deep_helper inhibit-start >/dev/null 2>&1 || ! deep_wait_until 3 _deep_inhibitor_listed; then
        deep_rollback "root inhibitor did not start"
        return 1
    fi

    # Step 5: optional dead-man timers (only with --timeout).
    local tsec; tsec=$(deep_state_get timeout_seconds 0)
    if [[ "$tsec" =~ ^[0-9]+$ ]] && (( tsec > 0 )); then
        deep_log "step 5/8: arming auto-revert timers (${tsec}s user, $(( tsec + 120 ))s root backup)"
        systemctl --user stop "${DEEP_USER_TIMER_UNIT}.timer" >/dev/null 2>&1 || true
        systemctl --user reset-failed "${DEEP_USER_TIMER_UNIT}.timer" "${DEEP_USER_TIMER_UNIT}.service" >/dev/null 2>&1 || true
        if ! systemd-run --user --unit="$DEEP_USER_TIMER_UNIT" --on-active="${tsec}s" --collect --quiet \
                "$self_bin" disable --auto-timeout >/dev/null 2>&1; then
            deep_rollback "user auto-revert timer failed"
            return 1
        fi
        if ! deep_helper revert-arm "$(( tsec + 120 ))" >/dev/null 2>&1; then
            deep_rollback "root backup revert timer failed"
            return 1
        fi
    else
        deep_log "step 5/8: no --timeout, no auto-revert timers created"
    fi

    # Step 6: close windows (only when the user typed 'yes' for them).
    local closed; closed=$(deep_state_get closed_clients "[]")
    if [[ "$closed" != "[]" ]]; then
        deep_log "step 6/8: closing open windows"
        omarchy-hyprland-window-close-all >/dev/null 2>&1 || true
        sleep "$DEEP_POLL"
        if ! deep_wait_until 10 _deep_no_clients; then
            local left; left=$(deep_list_gui_clients 2>/dev/null | cut -f1,2 | tr '\t\n' ': ' || true)
            deep_rollback "windows did not close (save dialog?): ${left}"
            return 1
        fi
    else
        deep_log "step 6/8: no open windows"
    fi

    # Step 7: stop the uwsm session (Omarchy's own logout path).
    deep_log "step 7/8: stopping the uwsm session"
    if ! uwsm stop >/dev/null 2>&1 || ! deep_wait_until 15 _deep_session_down; then
        if deep_session_active; then
            deep_rollback "uwsm stop failed; desktop still running"
        else
            deep_log "uwsm stop incomplete and session is gone; running exit sequence"
            exec 201>&-
            deep_exit_transaction "$config_file" "false" || true
        fi
        return 1
    fi

    # Step 8: stop the greeter so nothing graphical is left.
    if [[ "$(config_get_bool "$config_file" "deep" "stop_display_manager" "true")" != "true" ]]; then
        deep_log "step 8/8: [deep] stop_display_manager = false, leaving the greeter running"
        deep_state_set state '"DEEP_SERVER"'
        deep_log "DEEP_SERVER active (greeter kept)"
        exec 201>&-
        return 0
    fi
    deep_log "step 8/8: stopping display-manager.service"
    if ! deep_helper dm-stop >/dev/null 2>&1 || ! deep_wait_until 10 _deep_dm_inactive; then
        deep_log "display-manager did not stop; running exit sequence"
        exec 201>&-
        deep_exit_transaction "$config_file" "false" || true
        if ! deep_state_exists; then
            deep_write_last "rolled_back" "display-manager did not stop; desktop restored"
        fi
        return 1
    fi

    deep_state_set dm_stopped true
    local ram_after; ram_after=$(deep_available_mb)
    [[ -n "$ram_after" ]] && deep_state_set ram_after_mb "$ram_after"
    deep_state_set state '"DEEP_SERVER"'
    deep_log "DEEP_SERVER active (MemAvailable now ${ram_after:-?} MiB)"
    exec 201>&-
    return 0
}

# -----------------------------------------------------------------------------
# 7. Exit sequence (disable, timer, post-boot finalize)
# -----------------------------------------------------------------------------
deep_wait_for_desktop() {
    deep_wait_until "$1" deep_session_active
}

deep_has_autologin() {
    [[ -f "$DEEP_AUTOLOGIN_CONF" ]] && return 0
    grep -qs '^[[:space:]]*User=[^[:space:]]' "${DEEP_ROOT_PREFIX}/etc/sddm.conf" 2>/dev/null
}

# deep_exit_transaction <config> <is_auto_timeout>; 0 = back to HOST_LAPTOP, 1 = DEEP_DEGRADED/failed.
deep_exit_transaction() {
    local config_file="$1" is_auto="${2:-false}"
    deep_state_read >/dev/null || { ui_log_info "No Deep Server state."; return 0; }

    exec 201>"$DEEP_LOCK_FILE"
    if ! flock -w 10 201; then
        ui_log_fail "Another deep-mode transition holds $DEEP_LOCK_FILE." "Wait and retry 'oma-server disable'."
        return 1
    fi

    local wait_s
    wait_s=$(config_get_scalar "$config_file" "deep" "exit_wait_seconds" "45")
    [[ "$wait_s" =~ ^[0-9]+$ ]] && (( wait_s >= 1 && wait_s <= 600 )) || wait_s=45

    deep_state_set state '"DEEP_EXITING"'
    deep_log "exit: restoring the desktop"
    ui_log_sync "Restoring desktop: DEEP_SERVER -> HOST_LAPTOP"

    # Clear leftovers that make uwsm refuse to start (omarchy#9589).
    if systemctl --user is-active --quiet graphical-session.target 2>/dev/null; then
        systemctl --user stop graphical-session.target wayland-session@hyprland.desktop.target >/dev/null 2>&1 || true
    fi
    systemctl --user reset-failed 'wayland-wm@*' >/dev/null 2>&1 || true

    local back="false"
    if deep_session_active; then
        back="true"
    else
        # A running greeter (stop_display_manager = false, or a failed earlier exit) only
        # autologins again on a fresh start, so restart it; otherwise start it.
        local dm_verb="dm-start"
        deep_dm_active && dm_verb="dm-restart"
        if deep_helper_root "$dm_verb" >/dev/null; then
            deep_log "exit: display-manager ${dm_verb#dm-}ed, waiting up to ${wait_s}s for Hyprland"
            if ! deep_has_autologin && deep_wait_until 5 deep_dm_active; then
                # Password login: the greeter is the expected end state.
                back="greeter"
            elif deep_wait_for_desktop "$wait_s"; then
                back="true"
            else
                deep_log "exit: no Hyprland yet, restarting display-manager once"
                if deep_helper_root dm-restart >/dev/null && deep_wait_for_desktop "$wait_s"; then
                    back="true"
                fi
            fi
        else
            deep_log "exit: ${dm_verb} failed"
        fi
    fi

    local result="exited"
    if [[ "$back" == "greeter" ]]; then
        result="greeter"
        ui_log_info "Display manager is up without autologin: log in at the screen."
    elif [[ "$back" != "true" ]]; then
        if deep_dm_active && ! deep_has_autologin; then
            result="greeter"
            ui_log_info "Display manager is up without autologin: log in at the screen."
        else
            deep_state_set state '"DEEP_DEGRADED"'
            deep_log "exit: DEEP_DEGRADED (desktop did not come back within ${wait_s}s)"
            ui_log_fail "Desktop did not come back. Log in at the screen, or run 'oma-server disable' again." \
                "Panic: ${DEEP_PANIC_HINT}. The sleep/lid inhibitor is kept."
            exec 201>&-
            return 1
        fi
    fi

    deep_helper_root inhibit-stop >/dev/null || deep_log "WARN inhibit-stop failed"
    if [[ "$(deep_state_get timeout_seconds 0)" != "0" ]]; then
        deep_helper_root revert-disarm >/dev/null || deep_log "WARN revert-disarm failed"
    fi
    systemctl --user stop "${DEEP_USER_TIMER_UNIT}.timer" >/dev/null 2>&1 || true
    if [[ "$is_auto" != "true" ]]; then
        # Never stop our own unit when the timer itself invoked us.
        systemctl --user stop "${DEEP_USER_TIMER_UNIT}.service" >/dev/null 2>&1 || true
    fi
    deep_restore_linger
    deep_write_last "$result" ""
    rm -f "$DEEP_STATE_FILE"
    deep_log "exit: back to HOST_LAPTOP (${result})"
    exec 201>&-
    return 0
}

# Called at CLI start: a reboot means the desktop is already back.
deep_reconcile_boot() {
    deep_state_exists || return 0
    local boot; boot=$(deep_state_get boot_id "")
    [[ -n "$boot" && "$boot" != "$(deep_boot_id)" ]] || return 0
    deep_log "reboot detected (boot_id changed): clearing deep state"
    deep_helper inhibit-stop >/dev/null 2>&1 || true
    deep_restore_linger
    deep_write_last "rebooted" "machine rebooted while in $(deep_state_get state DEEP_SERVER)"
    rm -f "$DEEP_STATE_FILE"
}

# -----------------------------------------------------------------------------
# 8. deep-setup / deep-setup --remove (TTY only, plain sudo, prompts in terminal)
# -----------------------------------------------------------------------------
_deep_sudo_version_ok() {
    local v
    v=$(sudo -V 2>/dev/null | awk 'NR==1 {print $3}')
    [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
    (( a > 1 || (a == 1 && b > 9) || (a == 1 && b == 9 && c >= 10) ))
}

deep_config_set_allowed() {
    local config_file="$1" value="$2"
    [[ "$value" == "true" || "$value" == "false" ]] || return 1
    [[ -f "$config_file" ]] || return 1
    local tmp; tmp=$(mktemp "${config_file}.XXXXXX")
    awk -v val="$value" '
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_deep && !done) { print "allowed = " val; done = 1 }
            line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            in_deep = (line == "[deep]"); seen = seen || in_deep
            print; next
        }
        in_deep && /^[[:space:]]*allowed[[:space:]]*=/ { if (!done) { print "allowed = " val; done = 1 }; next }
        { print }
        END {
            if (in_deep && !done) { print "allowed = " val; done = 1 }
            if (!seen) { print ""; print "[deep]"; print "allowed = " val }
        }
    ' "$config_file" > "$tmp"
    chmod --reference="$config_file" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv -f "$tmp" "$config_file"
}

deep_setup() {
    local plugin_root="$1" config_file="$2"
    local helper_src="$plugin_root/libexec/oma-server-deep-helper"
    local sudoers_src="$plugin_root/templates/sudoers-oma-server-deep"

    if [[ ! -t 0 ]]; then
        ui_log_fail "deep-setup needs an interactive terminal (sudo will ask for your password)." \
            "Run it from a terminal or with 'ssh -t'."
        return 1
    fi
    [[ -f "$helper_src" && -f "$sudoers_src" ]] || { ui_log_fail "Helper or sudoers template missing under $plugin_root."; return 1; }
    command -v sudo >/dev/null 2>&1 || { ui_log_fail "sudo is not installed."; return 1; }
    _deep_sudo_version_ok || { ui_log_fail "sudo >= 1.9.10 is required (anchored-regex sudoers arguments)."; return 1; }
    if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
        ui_log_fail "Your user is not in the 'wheel' group; the %wheel grant would not apply." "Add yourself to wheel first."
        return 1
    fi
    if [[ -L "$DEEP_HELPER_DIR" || ( -e "$DEEP_HELPER_DIR" && ! -d "$DEEP_HELPER_DIR" ) ]]; then
        ui_log_fail "Refusing: $DEEP_HELPER_DIR exists but is not a real directory."
        return 1
    fi
    if [[ -L "$DEEP_HELPER_PATH" || -L "$DEEP_SUDOERS_PATH" ]]; then
        ui_log_fail "Refusing: an existing helper or sudoers path is a symlink."
        return 1
    fi
    if [[ -f "$config_file" ]] && [[ ! -w "$config_file" ]]; then
        ui_log_fail "Config file $config_file is not writable."
        return 1
    fi

    echo ""
    ui_log_info "Deep Server Mode setup will install (as root, via sudo):"
    printf "         %s  (root:root 0755, fixed verbs only)\n" "$DEEP_HELPER_PATH"
    printf "         %s  (root:root 0440, validated with visudo)\n" "$DEEP_SUDOERS_PATH"
    printf "\n         sudoers rule:\n"
    grep -v '^[[:space:]]*#' "$sudoers_src" | sed 's/^/           /'
    echo ""
    ui_log_warn "Any process running as a wheel user can then stop/start the desktop without a password (local DoS, no privilege escalation)."
    printf "%s Install the Deep Server Mode helper and sudoers rule? [y/N]: " "$(ui_badge_info)"
    local answer=""
    read -r answer || answer=""
    if [[ "${answer,,}" != "y" && "${answer,,}" != "yes" ]]; then
        ui_log_info "Cancelled. Nothing was installed."
        return 1
    fi

    local sudoers_dir="${DEEP_SUDOERS_PATH%/*}"
    local tmp_sudoers="${sudoers_dir}/.oma-server-deep.tmp"
    local tmp_helper="${DEEP_HELPER_DIR}/.deep-helper.tmp"

    # 1. Stage and validate the sudoers file first: if it does not parse, nothing is installed.
    #    (sudo ignores files in sudoers.d whose names contain a dot.)
    if ! sudo install -m 0440 "$sudoers_src" "$tmp_sudoers" || ! sudo chown root:root "$tmp_sudoers"; then
        sudo rm -f "$tmp_sudoers" || true
        ui_log_fail "Could not stage $tmp_sudoers."
        return 1
    fi
    if ! sudo visudo -cf "$tmp_sudoers" >/dev/null; then
        sudo rm -f "$tmp_sudoers" || true
        ui_log_fail "sudoers validation (visudo -cf) failed; nothing was installed."
        return 1
    fi

    # 2. Install the helper into a root-owned directory, atomically.
    if ! sudo mkdir -p "$DEEP_HELPER_DIR" || ! sudo chown root:root "$DEEP_HELPER_DIR" || ! sudo chmod 0755 "$DEEP_HELPER_DIR" || \
       ! sudo install -m 0755 "$helper_src" "$tmp_helper" || ! sudo chown root:root "$tmp_helper" || \
       ! sudo mv -f "$tmp_helper" "$DEEP_HELPER_PATH"; then
        sudo rm -f "$tmp_sudoers" "$tmp_helper" || true
        ui_log_fail "Could not install the helper; nothing was activated."
        return 1
    fi
    if ! cmp -s "$helper_src" "$DEEP_HELPER_PATH"; then
        sudo rm -f "$tmp_sudoers" "$DEEP_HELPER_PATH" || true
        ui_log_fail "Installed helper does not match the source; removed it."
        return 1
    fi

    # 3. Activate the grant atomically, then re-check the whole sudoers tree.
    if ! sudo mv -f "$tmp_sudoers" "$DEEP_SUDOERS_PATH"; then
        sudo rm -f "$tmp_sudoers" || true
        ui_log_fail "Could not activate $DEEP_SUDOERS_PATH."
        return 1
    fi
    if ! sudo visudo -c >/dev/null; then
        sudo rm -f "$DEEP_SUDOERS_PATH" || true
        ui_log_fail "Full sudoers check failed after activation; the rule was removed again."
        return 1
    fi

    if ! deep_grant_ok; then
        ui_log_warn "Installed, but 'sudo -n -l -l' does not show the grant as passwordless yet." \
            "Check that you are in 'wheel' (log out/in after adding the group)."
    fi
    if [[ ! -f "$config_file" ]]; then
        mkdir -p "${config_file%/*}"
        cp "$plugin_root/config/config.toml" "$config_file"
    fi
    deep_config_set_allowed "$config_file" true
    ui_log_ok "Deep Server Mode set up. Enter it with: oma-server enable --deep"
    return 0
}

deep_setup_remove() {
    local config_file="$1"
    if deep_state_exists; then
        ui_log_fail "Deep Server Mode is active ($(deep_state_get state UNKNOWN))." "Run 'oma-server disable' first."
        return 1
    fi
    if [[ -f "$config_file" ]]; then
        deep_config_set_allowed "$config_file" false || true
    fi
    if [[ ! -e "$DEEP_SUDOERS_PATH" && ! -e "$DEEP_HELPER_PATH" && ! -d "$DEEP_HELPER_DIR" ]]; then
        ui_log_info "Deep Server Mode helper and sudoers rule are not installed."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        ui_log_fail "Removing root files needs an interactive terminal (sudo password)." "Run it with 'ssh -t' or from a terminal."
        return 1
    fi
    # Revoke the grant first, then remove the helper.
    sudo rm -f "$DEEP_SUDOERS_PATH" "${DEEP_SUDOERS_PATH%/*}/.oma-server-deep.tmp" || { ui_log_fail "Could not remove $DEEP_SUDOERS_PATH."; return 1; }
    sudo rm -f "$DEEP_HELPER_PATH" "$DEEP_HELPER_DIR/.deep-helper.tmp" || { ui_log_fail "Could not remove $DEEP_HELPER_PATH."; return 1; }
    if [[ -d "$DEEP_HELPER_DIR" && ! -L "$DEEP_HELPER_DIR" ]]; then
        sudo rmdir "$DEEP_HELPER_DIR" 2>/dev/null || true
    fi
    ui_log_ok "Removed the Deep Server Mode helper and sudoers rule."
    return 0
}

# -----------------------------------------------------------------------------
# 9. Plan (diff --deep)
# -----------------------------------------------------------------------------
deep_render_plan() {
    local config_file="$1"
    local allowed grant="missing" ssh_state="inactive" linger
    allowed="$(config_get_bool "$config_file" "deep" "allowed" "false")"
    deep_helper_installed && deep_grant_ok && grant="ok (passwordless, fixed verbs)"
    systemctl is-active --quiet sshd.service 2>/dev/null && ssh_state="active"
    linger=$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null || echo "unknown")

    echo ""
    ui_log_info "Deep Server Mode plan (nothing is changed by this command)"
    printf "    %-28s %s\n" "[deep] allowed" "$allowed"
    printf "    %-28s %s\n" "root helper / sudo grant" "$grant"
    printf "    %-28s %s\n" "sshd.service" "$ssh_state"
    printf "    %-28s %s\n" "linger" "${linger} (enabled during deep mode, restored on exit)"
    echo ""
    printf "    %-28s %s\n" "STOP (user)" "$DEEP_SESSION_UNIT via 'uwsm stop' (Hyprland, bar, GUI apps)"
    printf "    %-28s %s\n" "STOP (system)" "display-manager.service (greeter)"
    printf "    %-28s %s\n" "START (system)" "oma-server-deep-inhibit.service (sleep:idle:handle-lid-switch)"
    printf "    %-28s %s\n" "TIMERS" "only with --timeout (oma-server-timer + root oma-server-deep-revert)"
    printf "    %-28s %s\n" "UNCHANGED" "default target, sshd, docker, systemd --user services"
    echo ""
    local clients
    if clients=$(deep_list_gui_clients); then
        if [[ -n "$clients" ]]; then
            ui_log_warn "Windows that would be closed (needs --close-apps + typed 'yes'):"
            printf "%s\n" "$clients" | awk -F'\t' '{printf "         - %s: %s (pid %s)\n", $1, $2, $3}'
        else
            ui_log_info "No open windows."
        fi
    else
        ui_log_warn "Could not list Hyprland windows."
    fi
    ui_log_info "Way back: 'oma-server disable' (SSH or Ctrl+Alt+F2), reboot, or '${DEEP_PANIC_HINT}'."
}
