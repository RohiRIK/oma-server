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
# S1: the prefix is test-only. Refuse it unless explicitly in test mode, as root,
# for anything but a real, user-owned, symlink-free absolute dir, or when a real
# sudo/pkexec would be used with it.
deep_guard_test_root() {
    [[ -n "$DEEP_ROOT_PREFIX" ]] || return 0
    [[ "${OMA_SERVER_TEST_MODE:-}" == 1 ]] || { echo "OMA_SERVER_TEST_ROOT is test-only (set OMA_SERVER_TEST_MODE=1)" >&2; exit 2; }
    [[ "$(id -u)" -ne 0 ]] || { echo "OMA_SERVER_TEST_ROOT refused as root" >&2; exit 2; }
    [[ "$DEEP_ROOT_PREFIX" == /* && -d "$DEEP_ROOT_PREFIX" \
       && "$(realpath -e -- "$DEEP_ROOT_PREFIX" 2>/dev/null)" == "$DEEP_ROOT_PREFIX" \
       && "$(stat -c %u -- "$DEEP_ROOT_PREFIX" 2>/dev/null)" == "$(id -u)" ]] || {
        echo "OMA_SERVER_TEST_ROOT must be a real, user-owned absolute dir" >&2; exit 2; }
    # N1: a real sudo/pkexec must not be reachable at all: not as a function, alias or
    # builtin, not via a symlink, and not as any setuid/setgid or root-owned binary.
    local b t r
    for b in sudo pkexec; do
        t=$(type -t "$b" 2>/dev/null || true)
        [[ -z "$t" ]] && continue
        [[ "$t" == file ]] || { echo "OMA_SERVER_TEST_ROOT refused: $b is a $t" >&2; exit 2; }
        r=$(realpath -e -- "$(type -P "$b")" 2>/dev/null) || { echo "OMA_SERVER_TEST_ROOT refused: $b unresolvable" >&2; exit 2; }
        if [[ -u "$r" || -g "$r" || "$(stat -c %u -- "$r" 2>/dev/null)" == 0 ]]; then
            echo "OMA_SERVER_TEST_ROOT refused: real $b reachable ($r)" >&2; exit 2
        fi
    done
    return 0
}
deep_guard_test_root
# Never let an inherited shell function (BASH_FUNC_sudo%%) stand in for sudo/pkexec.
# (In test mode the guard above has already refused one.)
unset -f sudo pkexec 2>/dev/null || true
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
# S2: the helper source is pinned by hash (test/deep.test.py keeps this in sync);
# the sudoers rule is generated here, never trusted from the user-writable plugin dir.
DEEP_HELPER_SHA256="09700eb01e6df72d82faac3fef73f0a3d49e1f266a36bcad70988c8da7ba4b65"
DEEP_HELPER_VERBS=(check dm-stop dm-start dm-restart inhibit-start inhibit-stop revert-disarm exit)

# Prints the exact sudoers file deep-setup installs.
deep_sudoers_expected() {
    local h="$DEEP_HELPER_REAL_PATH" v
    printf '%s\n' \
        "# /etc/sudoers.d/oma-server-deep -- installed only by \`oma-server deep-setup\` (opt-in)." \
        "# oma-server Deep Server Mode stops and restarts the graphical session, so the way back runs from SSH," \
        "# a TTY, or a root timer with no terminal or polkit agent to carry a prompt. Every verb is spelled out;" \
        "# revert-arm takes digits only and the helper revalidates them (5..604920)." \
        "# Remove with: oma-server deep-setup --remove"
    printf '%%wheel ALL=(root) NOPASSWD: %s %s, \\\n' "$h" "${DEEP_HELPER_VERBS[0]}"
    for v in "${DEEP_HELPER_VERBS[@]:1}"; do
        printf '    %s %s, \\\n' "$h" "$v"
    done
    printf '    %s ^revert-arm [1-9][0-9]{0\\,5}$\n' "$h"
}

# S3: a path must be root-owned (test mode: the user) and not group/other-writable.
_deep_path_safe() {
    local path="$1" want_uid=0 mode
    [[ -n "$DEEP_ROOT_PREFIX" ]] && want_uid="$(id -u)"
    [[ -e "$path" && ! -L "$path" ]] || return 1
    [[ "$(stat -c %u -- "$path" 2>/dev/null)" == "$want_uid" ]] || return 1
    mode=$(stat -c %a -- "$path" 2>/dev/null) || return 1
    (( (8#$mode & 8#022) == 0 ))
}

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
# The sudoers file is NOT checked here: /etc/sudoers.d is 0750 root on Arch, so a
# user cannot see it. The grant itself is checked by deep_grant_ok (sudo -n -l -l).
deep_helper_installed() {
    [[ -f "$DEEP_HELPER_PATH" && ! -L "$DEEP_HELPER_PATH" && -x "$DEEP_HELPER_PATH" ]] || return 1
    _deep_path_safe "$DEEP_HELPER_PATH" || return 1
    _deep_path_safe "$DEEP_HELPER_DIR" || return 1
    # Parents of the helper dir must not be writable by others either.
    _deep_path_safe "${DEEP_HELPER_DIR%/*}" || return 1
    _deep_path_safe "${DEEP_ROOT_PREFIX}/usr/local" || return 1
    return 0
}

# True when anything of the deep-mode root footprint is visible to the user.
deep_footprint_visible() {
    [[ -e "$DEEP_HELPER_PATH" || -d "$DEEP_HELPER_DIR" ]] && return 0
    deep_grant_ok && return 0
    [[ "$(deep_rule_listed)" == "yes" ]]
}

# B2: does 'sudo -n -l' still list a rule for the helper path? Works even when the
# helper itself is gone (orphaned sudoers file). Prints yes / no / unknown.
deep_rule_listed() {
    command -v sudo >/dev/null 2>&1 || { echo no; return 0; }
    local out
    if ! out=$(sudo -n -l 2>/dev/null); then
        echo unknown; return 0
    fi
    if printf "%s\n" "$out" | grep -qF -- "$DEEP_HELPER_PATH"; then echo yes; else echo no; fi
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

# Active OR still starting: a fresh session must never be torn down.
deep_session_present() {
    local st
    st=$(systemctl --user is-active "$DEEP_SESSION_UNIT" 2>/dev/null || true)
    [[ "$st" == "active" || "$st" == "activating" || "$st" == "reloading" ]]
}

deep_dm_active() {
    systemctl is-active --quiet display-manager.service 2>/dev/null
}

# Prints "class<TAB>title<TAB>pid" per open window. Fails if Hyprland is unreachable.
# Returns 1 (IPC error) unless hyprctl answered with a JSON array; retries a few times
# because Hyprland's IPC can time out while it is busy closing windows.
deep_list_gui_clients() {
    local out attempt
    for attempt in 1 2 3; do
        if out=$(run_with_timeout 5 hyprctl clients -j 2>/dev/null) && \
           printf "%s" "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
            printf "%s" "$out" | jq -r '.[] | "\(.class)\t\(.title)\t\(.pid)"'
            return 0
        fi
        (( attempt < 3 )) && sleep "$DEEP_POLL"
    done
    return 1
}

# Non-GUI processes in app-*.scope cgroups (tmux, agents, ...) die with the session.
# Processes that die with the session: every app-*.scope anywhere under app.slice
# (uwsm puts them in app.slice/app-graphical.slice/...), plus everything exec'd inside
# the compositor's own service cgroup. Hyprland, the bar/shell, session plumbing, the
# GUI clients already listed, and this command's own process chain are left out.
DEEP_SESSION_BOUND_IGNORE_RE='^(Hyprland|hyprland|quickshell|qs|omarchy-shell|omarchy-.*|waybar|uwsm|uwsm-app|start-hyprland|Xwayland|hyprpaper|hypridle|hyprsunset|swaybg|swayosd-server|mako|walker|elephant|fcitx5|systemd|dbus-daemon|dbus-broker|dbus-broker-launch|udiskie|socat|inotifywait|udevadm|wl-paste|wl-copy|capture.sh|hyprctl|jq|xkbcli-list|xkbcli)$'
# Processes started by the bar/shell; anything below them is shell plumbing.
DEEP_SESSION_BOUND_SHELL_RE='^(quickshell|qs|omarchy-shell|omarchy-launch-shell|omarchy-launch-s)$'

# True when the process (or its script, for `bash /path/x.sh`) lives in an Omarchy
# or oma-server plugin directory.
_deep_proc_is_omarchy_helper() {
    local pid="$1" arg i=0 dir
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    local -a dirs=(/usr/share/omarchy/ /usr/local/bin/omarchy- /usr/bin/omarchy-
                   /usr/local/lib/try-omarchy/ /usr/local/bin/host-window
                   "${HOME:-/nonexistent}/.local/share/omarchy/" "${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/omarchy/")
    [[ -n "${OMARCHY_PATH:-}" ]] && dirs+=("${OMARCHY_PATH%/}/")
    {
        while IFS= read -r -d '' arg && (( i < 2 )); do
            for dir in "${dirs[@]}"; do
                [[ "$arg" == "$dir"* ]] && return 0
            done
            i=$((i + 1))
        done < "/proc/$pid/cmdline"
    } 2>/dev/null
    return 1
}

# True when an ancestor (walking PPid up to Hyprland or pid 1) is the bar/shell, an
# Omarchy helper script, or one of the GUI windows already listed ($2).
_deep_proc_under_shell() {
    local p="$1" gui_pids="${2:-}" n=0 comm
    while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 && n < 64 )); do
        p=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null || true)
        [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 1
        [[ " $gui_pids " == *" $p "* ]] && return 0
        comm=$(tr -d '\000\n' 2>/dev/null < "/proc/$p/comm" || true)
        [[ "$comm" == "Hyprland" || "$comm" == "hyprland" || "$comm" == "systemd" ]] && return 1
        [[ "$comm" =~ $DEEP_SESSION_BOUND_SHELL_RE ]] && return 0
        _deep_proc_is_omarchy_helper "$p" && return 0
        n=$((n + 1))
    done
    return 1
}

# Processes that die with the session: every app-*.scope anywhere under app.slice
# (uwsm puts them in app.slice/app-graphical.slice/...), plus everything exec'd inside
# the compositor's own service cgroup. Hyprland, the bar/shell and everything it
# spawned, Omarchy's own helpers, the GUI clients already listed, and this command's
# own process chain are left out. Prints every match (pid<TAB>comm), uncapped.
deep_list_session_bound_procs() {
    local gui_pids="${1:-}"
    local uid="${UID:-$(id -u)}"
    local mgr="${OMA_SERVER_TEST_CGROUP_ROOT:-/sys/fs/cgroup}/user.slice/user-${uid}.slice/user@${uid}.service"
    [[ -d "$mgr" ]] || return 0
    local self_chain=" " p="$$" n=0
    while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 && n < 64 )); do
        self_chain+="$p "
        p=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null || true)
        n=$((n + 1))
    done
    local procs pid comm
    {
        [[ -d "$mgr/app.slice" ]] && find "$mgr/app.slice" -type d -name 'app-*.scope' 2>/dev/null
        [[ -d "$mgr/session.slice/$DEEP_SESSION_UNIT" ]] && find "$mgr/session.slice/$DEEP_SESSION_UNIT" -type d 2>/dev/null
    } | while IFS= read -r dir; do
        procs="$dir/cgroup.procs"
        [[ -r "$procs" ]] || continue
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            [[ " $gui_pids " == *" $pid "* ]] && continue
            [[ "$self_chain" == *" $pid "* ]] && continue
            [[ -r "/proc/$pid/comm" ]] || continue
            comm=$(tr -d '\000\n' 2>/dev/null < "/proc/$pid/comm" || true)
            [[ -z "$comm" || "$comm" =~ $DEEP_SESSION_BOUND_IGNORE_RE ]] && continue
            _deep_proc_is_omarchy_helper "$pid" && continue
            _deep_proc_under_shell "$pid" "$gui_pids" && continue
            # N5: never list a pid that exited while we were looking at it.
            [[ -d "/proc/$pid" ]] || continue
            printf "%s\t%s\n" "$pid" "$comm"
        done < "$procs"
    done | awk -F'\t' '!seen[$1]++'
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
    local gui_pids="" confirmed="false"
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
        (( timeout_sec == 0 )) && ui_log_warn "No --timeout: nothing will bring the desktop back on its own." \
            "Ways back: SSH 'oma-server disable'; Ctrl+Alt+F2 at the machine; reboot; or '${DEEP_PANIC_HINT}'."
        printf "%s Type 'yes' to close these windows and enter DEEP_SERVER: " "$(ui_badge_warn)"
        read -r answer || answer=""
        if [[ "$answer" != "yes" ]]; then
            ui_log_info "Not confirmed (expected the word 'yes'). Nothing was changed."
            return 3
        fi
        confirmed="true"
    fi

    local bound
    bound=$(deep_list_session_bound_procs "$gui_pids" || true)
    if [[ -n "$bound" ]]; then
        ui_log_warn "These session-bound processes will also stop (move agents to 'systemd-run --user' units or tmux started that way):"
        printf "%s\n" "$bound" | awk -F'\t' 'NR <= 20 {printf "         - %s (pid %s)\n", $2, $1}
            END { if (NR > 20) printf "         ...and %d more\n", NR - 20 }' >&2
    fi

    if (( timeout_sec == 0 )); then
        # With --close-apps the typed 'yes' above was the one confirmation.
        [[ "$confirmed" == "true" ]] || ui_log_warn "No --timeout: nothing will bring the desktop back on its own." \
            "Ways back: SSH 'oma-server disable'; Ctrl+Alt+F2 at the machine; reboot; or '${DEEP_PANIC_HINT}'."
        if deep_on_battery; then
            ui_log_warn "On battery: the sleep/lid inhibitor keeps the machine awake indefinitely (heat, drain)."
        fi
        if [[ -t 0 && "$confirmed" != "true" ]]; then
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
    local -a fwd=(HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY OMARCHY_PATH XDG_STATE_HOME XDG_CONFIG_HOME OMA_DEEP_POLL_INTERVAL)
    # The test-only prefix is forwarded only in test mode (S1).
    [[ "${OMA_SERVER_TEST_MODE:-}" == 1 ]] && fwd+=(OMA_SERVER_TEST_MODE OMA_SERVER_TEST_ROOT)
    for var in "${fwd[@]}"; do
        [[ -n "${!var:-}" ]] && setenv+=("--setenv=${var}=${!var}")
    done
    systemctl --user reset-failed "${DEEP_TRANSITION_UNIT}.service" >/dev/null 2>&1 || true
    if ! systemd-run --user --unit="$DEEP_TRANSITION_UNIT" --collect --quiet "${setenv[@]}" \
            "$self_bin" __deep-enter-worker >/dev/null 2>&1; then
        rm -f "$DEEP_STATE_FILE"
        ui_log_fail "Could not start the detached deep-mode transition (systemd-run --user failed)." "Nothing was changed."
        return 1
    fi

    deep_follow_enter "$config_file"
}

# N2: the follower must outlast the longest legitimate enter: the queued-job wait,
# the exit wait (a failed enter runs the exit sequence) and ~60s of steps.
deep_follow_seconds() {
    local config_file="$1" job_wait exit_wait
    job_wait=$(config_get_scalar "$config_file" "deep" "job_wait_seconds" "180")
    [[ "$job_wait" =~ ^[0-9]+$ ]] && (( job_wait <= 600 )) || job_wait=180
    exit_wait=$(config_get_scalar "$config_file" "deep" "exit_wait_seconds" "45")
    [[ "$exit_wait" =~ ^[0-9]+$ ]] && (( exit_wait >= 1 && exit_wait <= 600 )) || exit_wait=45
    echo $(( job_wait + exit_wait + 60 ))
}

# Tails deep.log until the worker reaches DEEP_SERVER or rolls back.
deep_follow_enter() {
    local config_file="${1:-}"
    local follow_max="${OMA_DEEP_FOLLOW_SECONDS:-}"
    # INFO-5: never feed an unvalidated env value into arithmetic.
    [[ "$follow_max" =~ ^[0-9]+$ ]] || follow_max=$(deep_follow_seconds "$config_file")
    local deadline=$(( $(date +%s) + follow_max ))
    local printed=0 total line state
    _deep_follow_print() {
        [[ -f "$DEEP_LOG_FILE" ]] || return 0
        total=$(wc -l < "$DEEP_LOG_FILE")
        if (( total > printed )); then
            while IFS= read -r line; do
                printf "  %s %s\n" "$(ui_badge_sync)" "${line#* }"
            done < <(tail -n +"$(( printed + 1 ))" "$DEEP_LOG_FILE" | head -n "$(( total - printed ))")
            printed=$total
        fi
    }
    # B4: once the outcome is known, let the worker finish and print deep.log to EOF.
    _deep_follow_drain() {
        local i
        for (( i = 0; i < 50; i++ )); do
            systemctl --user is-active --quiet "${DEEP_TRANSITION_UNIT}.service" 2>/dev/null || break
            sleep 0.1
        done
        _deep_follow_print
    }
    while :; do
        _deep_follow_print
        if ! deep_state_exists; then
            _deep_follow_drain
            local reason=""
            reason=$(jq -r '.reason // ""' "$DEEP_LAST_FILE" 2>/dev/null || true)
            ui_log_fail "Deep Server Mode was not entered; changes were rolled back${reason:+: $reason}."
            return 1
        fi
        state=$(deep_state_get state "")
        case "$state" in
            DEEP_SERVER)
                _deep_follow_drain
                ui_log_ok "DEEP_SERVER active. Desktop is stopped; run 'oma-server disable' to bring it back."
                return 0
                ;;
            DEEP_DEGRADED)
                _deep_follow_drain
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

_DEEP_LAST_CLIENTS_ERR=""
_deep_no_clients() {
    local c
    if ! c=$(deep_list_gui_clients 2>/dev/null); then
        _DEEP_LAST_CLIENTS_ERR="ipc"
        return 1
    fi
    _DEEP_LAST_CLIENTS_ERR=""
    [[ -z "$c" ]]
}

_deep_no_user_jobs() {
    [[ -z "$(systemctl --user list-jobs --no-legend 2>/dev/null)" ]]
}

# Units with a queued/running user job (first column of list-jobs is the job id).
_deep_queued_units() {
    systemctl --user list-jobs --no-legend 2>/dev/null | awk '{print $2}' | head -n 5 | paste -sd ' ' -
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
            local left=""
            if left=$(deep_list_gui_clients 2>/dev/null); then
                left=$(printf "%s" "$left" | cut -f1,2 | tr '\t\n' ': ')
                deep_rollback "windows did not close (save dialog?): ${left}"
            else
                deep_rollback "could not verify windows closed (hyprctl IPC error)"
            fi
            return 1
        fi
    else
        deep_log "step 6/8: no open windows"
    fi

    # Step 7: stop the uwsm session (Omarchy's own logout path).
    deep_log "step 7/8: stopping the uwsm session"
    local uwsm_ok="false" uwsm_out=""
    if uwsm_out=$(uwsm stop 2>&1); then
        uwsm_ok="true"
    else
        # e.g. org.freedesktop.systemd1.TransactionIsDestructive while a user start job
        # is still queued: wait for the job queue to drain, then retry once.
        # B3: wait for the user job queue to drain (default 180s covers slow startup
        # jobs; [deep] job_wait_seconds, 0..600), then retry once.
        local job_wait queued=""
        job_wait=$(config_get_scalar "$config_file" "deep" "job_wait_seconds" "180")
        [[ "$job_wait" =~ ^[0-9]+$ ]] && (( job_wait <= 600 )) || job_wait=180
        deep_log "uwsm stop refused ($(printf "%s" "$uwsm_out" | grep -o 'TransactionIsDestructive' | head -n 1 || true)); waiting up to ${job_wait}s for queued user jobs, then retrying once"
        if ! deep_wait_until "$job_wait" _deep_no_user_jobs; then
            queued=$(_deep_queued_units)
            deep_log "user jobs still queued after ${job_wait}s: ${queued:-?}"
        fi
        uwsm stop >/dev/null 2>&1 && uwsm_ok="true"
    fi
    if [[ "$uwsm_ok" != "true" ]] || ! deep_wait_until 15 _deep_session_down; then
        if deep_session_active; then
            if [[ -n "${queued:-}" ]]; then
                deep_rollback "uwsm stop refused: a start job is still queued: ${queued}"
            else
                deep_rollback "uwsm stop failed; desktop still running"
            fi
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
        deep_log "DEEP_SERVER active (greeter kept)"
        deep_state_set state '"DEEP_SERVER"'
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
    deep_log "DEEP_SERVER active (MemAvailable now ${ram_after:-?} MiB)"
    deep_state_set state '"DEEP_SERVER"'
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

    local from_state; from_state=$(deep_state_get state "DEEP_SERVER")
    deep_state_set state '"DEEP_EXITING"'
    deep_log "exit: restoring the desktop (from ${from_state})"
    ui_log_sync "Restoring desktop: ${from_state} -> HOST_LAPTOP"

    local back="false" fail_reason=""
    if deep_session_present; then
        # The desktop is already back (root backup timer, manual login): never stop
        # graphical-session.target here, it belongs to the fresh session.
        deep_log "exit: session already present, finishing cleanup only"
        if deep_wait_for_desktop "$wait_s"; then
            back="true"
        else
            fail_reason="session did not become active within ${wait_s}s"
        fi
    else
        # Clear leftovers that make uwsm refuse to start (omarchy#9589), only while
        # no session exists.
        if systemctl --user is-active --quiet graphical-session.target 2>/dev/null; then
            systemctl --user stop graphical-session.target wayland-session@hyprland.desktop.target >/dev/null 2>&1 || true
        fi
        systemctl --user reset-failed 'wayland-wm@*' >/dev/null 2>&1 || true

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
                if ! deep_helper_root dm-restart >/dev/null; then
                    fail_reason="dm-restart failed"
                elif deep_wait_for_desktop "$wait_s"; then
                    back="true"
                else
                    fail_reason="desktop did not come back within ${wait_s}s (after one dm-restart)"
                fi
            fi
        else
            fail_reason="${dm_verb} failed"
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
            deep_log "exit: DEEP_DEGRADED (${fail_reason:-desktop did not come back})"
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
    # S2: never trust the user-writable copies. The helper must match the pinned hash
    # and the template must equal the rule generated in code, before any sudo.
    local src_sha
    src_sha=$(sha256sum "$helper_src" 2>/dev/null | awk '{print $1}')
    if [[ "$src_sha" != "$DEEP_HELPER_SHA256" ]]; then
        ui_log_fail "Refusing: $helper_src does not match the pinned helper hash (modified copy?)." \
            "Reinstall oma-server from a clean checkout."
        return 1
    fi
    if ! cmp -s "$sudoers_src" <(deep_sudoers_expected); then
        ui_log_fail "Refusing: $sudoers_src differs from the rule oma-server generates (modified copy?)." \
            "Reinstall oma-server from a clean checkout."
        return 1
    fi
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
    if [[ -L "$DEEP_HELPER_PATH" ]]; then
        ui_log_fail "Refusing: the existing helper path is a symlink."
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
    deep_sudoers_expected | grep -v '^[[:space:]]*#' | sed 's/^/           /'
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

    # /etc/sudoers.d is root-only, so the symlink check needs sudo.
    if sudo test -L "$DEEP_SUDOERS_PATH"; then
        ui_log_fail "Refusing: $DEEP_SUDOERS_PATH is a symlink."
        return 1
    fi

    # Private snapshots of what will be installed (generated rule, hashed helper).
    local work; work=$(mktemp -d)
    chmod 0700 "$work"
    deep_sudoers_expected > "$work/sudoers"
    cp "$helper_src" "$work/helper"
    if [[ "$(sha256sum "$work/helper" | awk '{print $1}')" != "$DEEP_HELPER_SHA256" ]]; then
        rm -rf "$work"; ui_log_fail "Helper changed while staging; aborted."; return 1
    fi

    # 1. Stage and validate the sudoers file first: if it does not parse or does not
    #    match the generated rule byte-for-byte, nothing is installed.
    #    (sudo ignores files in sudoers.d whose names contain a dot.)
    if ! sudo install -m 0440 "$work/sudoers" "$tmp_sudoers" || ! sudo chown root:root "$tmp_sudoers"; then
        sudo rm -f "$tmp_sudoers" || true
        rm -rf "$work"
        ui_log_fail "Could not stage $tmp_sudoers."
        return 1
    fi
    if ! sudo cat "$tmp_sudoers" | cmp -s - <(deep_sudoers_expected); then
        sudo rm -f "$tmp_sudoers" || true
        rm -rf "$work"
        ui_log_fail "Staged sudoers file does not match the generated rule; nothing was installed."
        return 1
    fi
    if ! sudo visudo -cf "$tmp_sudoers" >/dev/null; then
        rm -rf "$work"
        sudo rm -f "$tmp_sudoers" || true
        ui_log_fail "sudoers validation (visudo -cf) failed; nothing was installed."
        return 1
    fi

    # 2. Install the helper into a root-owned directory, atomically.
    if ! sudo mkdir -p "$DEEP_HELPER_DIR" || ! sudo chown root:root "$DEEP_HELPER_DIR" || ! sudo chmod 0755 "$DEEP_HELPER_DIR" || \
       ! sudo install -m 0755 "$work/helper" "$tmp_helper" || ! sudo chown root:root "$tmp_helper"; then
        sudo rm -f "$tmp_sudoers" "$tmp_helper" || true
        rm -rf "$work"
        ui_log_fail "Could not install the helper; nothing was activated."
        return 1
    fi
    rm -rf "$work"
    # Verify the root-owned staged copy (not the user-writable source) before the rename.
    if [[ "$(sudo sha256sum "$tmp_helper" | awk '{print $1}')" != "$DEEP_HELPER_SHA256" ]] || \
       ! sudo mv -f "$tmp_helper" "$DEEP_HELPER_PATH"; then
        sudo rm -f "$tmp_sudoers" "$tmp_helper" || true
        ui_log_fail "Staged helper does not match the pinned hash; nothing was activated."
        return 1
    fi
    # S3: refuse to activate the grant over a helper or directory others can write.
    if ! _deep_path_safe "$DEEP_HELPER_PATH" || ! _deep_path_safe "$DEEP_HELPER_DIR" || \
       ! _deep_path_safe "${DEEP_HELPER_DIR%/*}"; then
        sudo rm -f "$tmp_sudoers" || true
        ui_log_fail "Helper or one of its directories is group/world-writable or not root-owned; grant NOT activated."
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
    # /etc/sudoers.d is not readable by the user, so "installed" is judged by the
    # visible helper/dir or the grant probe; with a TTY we always remove both paths.
    if [[ ! -t 0 ]]; then
        if deep_footprint_visible; then
            ui_log_fail "Removing root files needs an interactive terminal (sudo password)." "Run it with 'ssh -t' or from a terminal."
            return 1
        fi
        [[ -f "$config_file" ]] && { deep_config_set_allowed "$config_file" false || true; }
        ui_log_info "No Deep Server Mode helper or grant is visible. Run with a TTY to also clear $DEEP_SUDOERS_PATH as root."
        return 0
    fi
    # Revoke the grant first, then remove the helper.
    sudo rm -f "$DEEP_SUDOERS_PATH" "${DEEP_SUDOERS_PATH%/*}/.oma-server-deep.tmp" || { ui_log_fail "Could not remove $DEEP_SUDOERS_PATH."; return 1; }
    sudo rm -f "$DEEP_HELPER_PATH" "$DEEP_HELPER_DIR/.deep-helper.tmp" || { ui_log_fail "Could not remove $DEEP_HELPER_PATH."; return 1; }
    if [[ -d "$DEEP_HELPER_DIR" && ! -L "$DEEP_HELPER_DIR" ]]; then
        sudo rmdir "$DEEP_HELPER_DIR" 2>/dev/null || true
    fi
    [[ -f "$config_file" ]] && { deep_config_set_allowed "$config_file" false || true; }
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

# -----------------------------------------------------------------------------
# 9. Optional deep console shell (`oma-server deep-shell`), user-level only.
# Default "none" = plain tty1 `login:` console and no profile edits at all.
# Any other choice writes [deep] shell = "<name>" and a managed block into the
# login profile that runs libexec/oma-server-deep-shell (tty1 + DEEP_SERVER only).
# -----------------------------------------------------------------------------
DEEP_SHELL_CHOICES=(none tmux btop tuios zellij custom)
DEEP_SHELL_BEGIN="# >>> oma-server deep shell >>>"
DEEP_SHELL_END="# <<< oma-server deep shell <<<"

deep_shell_profile_file() {
    case "$(basename -- "${SHELL:-bash}")" in
        zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zprofile" ;;
        *)   printf '%s' "$HOME/.bash_profile" ;;
    esac
}

deep_shell_binary() {
    case "$1" in
        none) printf '' ;; custom) printf 'bash' ;; *) printf '%s' "$1" ;;
    esac
}

# Sets or adds `key = "value"` inside [deep] (atomic rewrite, keeps comments).
deep_config_set_string() {
    local file="$1" key="$2" val="$3" tmp
    [[ -f "$file" && ! -L "$file" ]] || { ui_log_fail "Config '$file' missing or a symlink."; return 1; }
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk -v k="$key" -v v="$val" '
        function emit() { printf "%s = \"%s\"\n", k, v; done=1 }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            if (in_sec && !done) emit()
            s=$0; gsub(/[[:space:]]/,"",s); in_sec=(s=="[deep]"); print; next
        }
        in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) emit(); next }
        { print }
        END { if (!done) { if (!in_sec) print "\n[deep]"; emit() } }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"; return 1
    fi
}

deep_shell_profile_remove() {
    local prof="$1" tmp
    [[ -f "$prof" ]] || return 0
    grep -qF "$DEEP_SHELL_BEGIN" "$prof" || return 0
    tmp=$(mktemp "${prof}.XXXXXX") || return 1
    # Drop the block and the one blank line deep_shell_profile_add put before it.
    awk -v b="$DEEP_SHELL_BEGIN" -v e="$DEEP_SHELL_END" '
        $0==b { held=0; skip=1; next }  $0==e { skip=0; next }  skip { next }
        held { print ""; held=0 }  $0=="" { held=1; next }  { print }
        END { if (held) print "" }' "$prof" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$prof" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$prof"
}

deep_shell_profile_add() {
    local prof="$1" launcher="$2"
    deep_shell_profile_remove "$prof" || return 1
    [[ -L "$prof" ]] && { ui_log_fail "'$prof' is a symlink; add the block by hand."; return 1; }
    # The launcher path is written into a shell profile: refuse anything that could be
    # interpreted there.
    if [[ "$launcher" == *[\"\$\`\\]* || "$launcher" == *$'\n'* ]]; then
        ui_log_fail "Launcher path '$launcher' contains shell metacharacters; add the block by hand."
        return 1
    fi
    # shellcheck disable=SC2016  # literal $(tty) belongs in the profile, not expanded here
    {
        printf '\n%s\n' "$DEEP_SHELL_BEGIN"
        printf '# Added by `oma-server deep-shell`. Runs only on tty1 while Deep Server Mode is active.\n'
        printf '# Remove with: oma-server deep-shell none\n'
        printf 'if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ -x "%s" ]; then\n' "$launcher"
        printf '    "%s" login\n' "$launcher"
        printf 'fi\n%s\n' "$DEEP_SHELL_END"
    } >> "$prof"
}

# oma-server deep-shell            -> show current choice and what is installed
# oma-server deep-shell <name>     -> set it (none removes the profile block)
# oma-server deep-shell custom --command "<cmd>"
deep_shell_cmd() {
    local plugin_root="$1" config_file="$2"; shift 2
    local launcher="$plugin_root/libexec/oma-server-deep-shell"
    local prof; prof=$(deep_shell_profile_file)
    local current; current=$(config_get_scalar "$config_file" "deep" "shell" "none")

    if (( $# == 0 )); then
        ui_log_info "Deep console shell: $current (profile: $prof)"
        local c b mark
        for c in "${DEEP_SHELL_CHOICES[@]}"; do
            b=$(deep_shell_binary "$c"); mark="installed"
            [[ -n "$b" ]] && ! command -v "$b" >/dev/null 2>&1 && mark="not installed"
            [[ "$c" == none ]] && mark="plain console + login: prompt (default)"
            [[ "$c" == custom ]] && mark="[deep] shell_command"
            printf '  %s %-7s %s\n' "$([[ $c == "$current" ]] && echo '*' || echo ' ')" "$c" "$mark"
        done
        return 0
    fi

    local choice="$1"; shift
    if [[ " ${DEEP_SHELL_CHOICES[*]} " != *" $choice "* ]]; then
        ui_log_fail "Unknown deep shell '$choice'." "Choose one of: ${DEEP_SHELL_CHOICES[*]}"
        return 1
    fi
    if [[ "$choice" == custom ]]; then
        [[ "${1:-}" == "--command" && -n "${2:-}" ]] || { ui_log_fail "custom needs --command \"<cmd>\"."; return 1; }
        [[ "$2" != *'"'* && "$2" != *$'\n'* && "$2" != *\\* ]] || { ui_log_fail "The command may not contain double quotes, backslashes or newlines."; return 1; }
        deep_config_set_string "$config_file" "shell_command" "$2" || return 1
    fi
    deep_config_set_string "$config_file" "shell" "$choice" || return 1

    if [[ "$choice" == none ]]; then
        deep_shell_profile_remove "$prof" || return 1
        ui_log_ok "Deep console: plain shell with a login: prompt (profile block removed)."
        return 0
    fi
    [[ -x "$launcher" ]] || { ui_log_fail "Launcher '$launcher' missing; re-run install.sh."; return 1; }
    deep_shell_profile_add "$prof" "$launcher" || return 1
    local b; b=$(deep_shell_binary "$choice")
    if ! command -v "$b" >/dev/null 2>&1; then
        ui_log_warn "'$b' is not installed yet; tty1 will fall back to the plain shell until it is."
    fi
    ui_log_ok "Deep console: log in on tty1, then $choice starts (any key within 3 s skips it; quitting returns to the shell)."
}
