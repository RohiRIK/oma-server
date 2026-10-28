#!/usr/bin/env bash
# install.sh - Production installer for oma-server on Omarchy Linux systems.
# Enforces pre-flight validation, safe file permissions, and zero-emoji status badges.
set -euo pipefail

# omarchy-shell / omarchy-plugin-catalog need OMARCHY_PATH; it is only set inside
# the graphical session, so default it for plain SSH / non-login shells.
: "${OMARCHY_PATH:=/usr/share/omarchy}"
export OMARCHY_PATH

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/server-mode"
BIN_DIR="$HOME/.local/bin"
HOOK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks/post-boot.d"
SHELL_PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/rohirik.oma-server"

# Source UI helpers if available for consistent formatting
if [[ -f "$SCRIPT_DIR/lib/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/ui.sh"
else
    ui_log_info() { printf "[ INFO ] %s\n" "$1"; }
    ui_log_ok()   { printf "[ OK ] %s\n" "$1"; }
    ui_log_warn() { printf "[ WARN ] %s\n" "$1" >&2; }
    ui_log_fail() { printf "[ FAIL ] %s\n" "$1" >&2; }
fi

# 1. Pre-flight verification of required repository files
for req_file in \
    "bin/oma-server" \
    "lib/ui.sh" \
    "lib/config.sh" \
    "lib/snapshot.sh" \
    "lib/transition.sh" \
    "lib/deep.sh" \
    "libexec/oma-server-deep-helper" \
    "libexec/oma-server-deep-shell" \
    "templates/sudoers-oma-server-deep" \
    "config/config.toml" \
    "hooks/post-boot.d/99-server-profile-check.sh" \
    "manifest.json" \
    "Panel.qml"; do
    if [[ ! -f "$SCRIPT_DIR/$req_file" ]]; then
        ui_log_fail "Required package artifact '$req_file' is missing from '$SCRIPT_DIR'."
        exit 1
    fi
done

ui_log_info "Installing oma-server core runtime to: $TARGET_DIR"
mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$TARGET_DIR/libexec" "$TARGET_DIR/templates" "$BIN_DIR" "$HOOK_DIR"

# 2. Install modular libraries and CLI coordinator
cp -f "$SCRIPT_DIR/lib/ui.sh" \
      "$SCRIPT_DIR/lib/config.sh" \
      "$SCRIPT_DIR/lib/snapshot.sh" \
      "$SCRIPT_DIR/lib/transition.sh" \
      "$SCRIPT_DIR/lib/deep.sh" \
      "$TARGET_DIR/lib/"
# Deep Server Mode sources (user dir only). Nothing root-owned is installed here:
# the helper and sudoers rule are installed only by the opt-in `oma-server deep-setup`.
cp -f "$SCRIPT_DIR/libexec/oma-server-deep-helper" "$TARGET_DIR/libexec/"
cp -f "$SCRIPT_DIR/libexec/oma-server-deep-shell" "$TARGET_DIR/libexec/"
chmod 0755 "$TARGET_DIR/libexec/oma-server-deep-shell"
cp -f "$SCRIPT_DIR/templates/sudoers-oma-server-deep" "$TARGET_DIR/templates/"
chmod 0755 "$TARGET_DIR/libexec/oma-server-deep-helper"
chmod 0644 "$TARGET_DIR/templates/sudoers-oma-server-deep"
cp -f "$SCRIPT_DIR/bin/oma-server" "$TARGET_DIR/bin/omarchy-server-mode"
cp -f "$SCRIPT_DIR/bin/oma-server" "$TARGET_DIR/bin/oma-server"
chmod 0755 "$TARGET_DIR/bin/omarchy-server-mode" "$TARGET_DIR/bin/oma-server" "$TARGET_DIR/lib/"*.sh

# 3. Install default config if not already present (non-destructive)
if [[ ! -f "$TARGET_DIR/config.toml" ]]; then
    ui_log_info "Creating default configuration at: $TARGET_DIR/config.toml"
    cp "$SCRIPT_DIR/config/config.toml" "$TARGET_DIR/config.toml"
    chmod 0644 "$TARGET_DIR/config.toml"
else
    ui_log_info "Existing user configuration preserved at: $TARGET_DIR/config.toml"
fi

# 4. Install post-boot recovery hook
ui_log_info "Installing post-boot safety hook to: $HOOK_DIR/99-server-profile-check.sh"
cp -f "$SCRIPT_DIR/hooks/post-boot.d/99-server-profile-check.sh" "$HOOK_DIR/99-server-profile-check.sh"
chmod 0755 "$HOOK_DIR/99-server-profile-check.sh"

# 5. Configure CLI symlinks in ~/.local/bin
ui_log_info "Linking CLI entrypoints in: $BIN_DIR"
ln -sf "$TARGET_DIR/bin/omarchy-server-mode" "$BIN_DIR/oma-server"
ln -sf "$TARGET_DIR/bin/omarchy-server-mode" "$BIN_DIR/omarchy-server-mode"

# 6. Install Omarchy Quickshell bar-widget plugin and purge deprecated BarWidget.qml
ui_log_info "Configuring Quickshell bar widget at: $SHELL_PLUGIN_DIR"
mkdir -p "$SHELL_PLUGIN_DIR"
if [[ -f "$SHELL_PLUGIN_DIR/BarWidget.qml" ]]; then
    ui_log_info "Removing deprecated BarWidget.qml artifact from: $SHELL_PLUGIN_DIR"
    rm -f "$SHELL_PLUGIN_DIR/BarWidget.qml"
fi
if [[ "$(realpath "$SHELL_PLUGIN_DIR")" != "$(realpath "$SCRIPT_DIR")" ]]; then
    cp -f "$SCRIPT_DIR/manifest.json" "$SCRIPT_DIR/Panel.qml" "$SHELL_PLUGIN_DIR/"
fi

# 7. Synchronize live Quickshell plugin cache & register widget
#
# Restarting the shell is only safe from inside the graphical session: over SSH
# (no WAYLAND_DISPLAY / HYPRLAND_INSTANCE_SIGNATURE) omarchy-restart-shell kills
# the running bar and the replacement cannot attach to the compositor, leaving
# the desktop with no bar. Outside a graphical session we only ask the running
# shell to rescan plugins over IPC and never kill it.
has_graphical_session() {
    [[ -n "${WAYLAND_DISPLAY:-}" && -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]
}

CURRENT_UID="${UID:-$(id -u)}"

# Test/tuning knobs, validated before any arithmetic or sleep (Sam INFO-2: bash
# arithmetic would evaluate a payload like 'a[$(cmd)]').
_num_or() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf "%s" "$1" || printf "%s" "$2"; }
enable_tries="${OMA_INSTALL_ENABLE_TRIES:-6}"
[[ "$enable_tries" =~ ^[0-9]+$ ]] && (( 10#$enable_tries >= 1 && 10#$enable_tries <= 20 )) || enable_tries=6
enable_tries=$(( 10#$enable_tries ))
enable_step="$(_num_or "${OMA_INSTALL_ENABLE_BACKOFF:-1}" 1)"
ipc_poll="$(_num_or "${OMA_INSTALL_IPC_POLL:-0.5}" 0.5)"
ipc_wait="$(_num_or "${OMA_INSTALL_IPC_WAIT:-10}" 10)"

live_shell_pids() {
    pgrep -u "$CURRENT_UID" -x "quickshell" 2>/dev/null || true
}

# True when the running shell answers over IPC. Prefers 'omarchy-shell shell ping';
# without it, a live quickshell pid must own a listening by-pid/<pid>/ipc.sock
# (stale sockets of dead shells are ignored, by-id/* is never trusted on its own).
shell_ipc_ok() {
    if command -v omarchy-shell >/dev/null 2>&1; then
        OMARCHY_SHELL_IPC_TIMEOUT=2s omarchy-shell shell ping >/dev/null 2>&1 && return 0
    fi
    local qs_dir="${XDG_RUNTIME_DIR:-/run/user/$CURRENT_UID}/quickshell" pid
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ -S "$qs_dir/by-pid/$pid/ipc.sock" ]] && return 0
    done < <(live_shell_pids)
    return 1
}

# Waits up to $1 seconds for a live shell that answers IPC.
wait_for_shell_ipc() {
    local max="${1:-10}" i n
    n=$(awk -v m="$max" -v p="$ipc_poll" 'BEGIN { if (p <= 0) p = 0.5; printf "%d", m / p }')
    for (( i = 0; i <= n; i++ )); do
        [[ -n "$(live_shell_pids)" ]] && shell_ipc_ok && return 0
        sleep "$ipc_poll"
    done
    return 1
}

# N7: omarchy-restart-shell can leave no bar at all on a slow machine (its 'timeout 5
# quickshell kill' loop starts the new shell while the old one still runs; the new one
# refuses, then the old one exits). Make sure a shell is alive and answering, and
# relaunch it inside the session if it is gone.
ensure_shell_alive() {
    local old_pids="$1"
    wait_for_shell_ipc "$ipc_wait" && {
        # An old instance that is still exiting may have answered; re-check once it settles.
        sleep "$ipc_poll"
        [[ -n "$(live_shell_pids)" ]] && return 0
    }
    if [[ -z "$(live_shell_pids)" ]] && command -v hyprctl >/dev/null 2>&1; then
        ui_log_warn "omarchy-shell is not running after the restart; relaunching it."
        local out
        out=$(hyprctl dispatch 'hl.dsp.exec_cmd("omarchy-launch-shell")' 2>/dev/null || true)
        [[ "$out" == *ok* ]] || hyprctl dispatch exec omarchy-launch-shell >/dev/null 2>&1 || true
        wait_for_shell_ipc "$(awk -v w="$ipc_wait" 'BEGIN { print w * 2 }')" && return 0
    fi
    [[ -n "$old_pids" ]] && ui_log_warn "omarchy-shell did not come back answering IPC."
    return 1
}

widget_status="skipped"
widget_detail=""

if pgrep -u "$CURRENT_UID" -x "quickshell" >/dev/null 2>&1 || pgrep -u "$CURRENT_UID" -x "omarchy-shell" >/dev/null 2>&1; then
    pkill -CONT -u "$CURRENT_UID" -x "quickshell" 2>/dev/null || true
    pkill -CONT -u "$CURRENT_UID" -x "omarchy-shell" 2>/dev/null || true
    # Wait briefly for Quickshell's 150ms localPluginReloadTimer debounce to settle
    sleep 0.4

    if has_graphical_session && command -v omarchy-restart-shell >/dev/null 2>&1; then
        ui_log_info "Reloading omarchy-shell QML type cache..."
        shell_pids_before="$(live_shell_pids | tr '\n' ' ')"
        if ! omarchy-restart-shell >/dev/null 2>&1; then
            omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
            sleep 0.6
        fi
        ensure_shell_alive "$shell_pids_before" || true
    else
        if ! has_graphical_session; then
            ui_log_info "No graphical session detected (e.g. SSH); not restarting omarchy-shell, rescanning plugins instead."
        fi
        if command -v omarchy-shell >/dev/null 2>&1; then
            omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
            sleep 0.6
        fi
    fi

    if command -v omarchy >/dev/null 2>&1; then
        enable_out=""
        enable_rc=1
        # The shell may still be restarting (right after uninstall's 'plugin disable'
        # or omarchy-restart-shell), which shows up as an IPC timeout or
        # 'QLocalSocket::PeerClosedError'. Wait for the quickshell IPC socket, then
        # retry with a growing backoff (1+2+3+4+5 s by default, ~15 s in total).
        wait_for_shell_ipc "$ipc_wait" || true
        for (( _attempt = 1; _attempt <= enable_tries; _attempt++ )); do
            enable_rc=0
            enable_out=$(OMARCHY_SHELL_IPC_TIMEOUT=5s omarchy plugin enable rohirik.oma-server --section right 2>&1) || enable_rc=$?
            # omarchy-plugin-enable is idempotent: an already-enabled widget still
            # returns exit 0 ("Enabled and moved <id>"), so exit status is the signal.
            (( enable_rc == 0 )) && break
            (( _attempt < enable_tries )) || break
            if [[ "$enable_out" == *PeerClosedError* || "$enable_out" == *"timed out"* || "$enable_out" == *"Socket Error"* ]]; then
                wait_for_shell_ipc "$ipc_wait" || true
            fi
            sleep "$(awk -v a="$_attempt" -v s="$enable_step" 'BEGIN { printf "%.2f", a * s }')"
        done
        if (( enable_rc == 0 )); then
            widget_status="enabled"
        else
            widget_status="failed"
            widget_detail="$(printf '%s' "$enable_out" | head -n 1)"
        fi
    else
        widget_detail="'omarchy' CLI not found"
    fi
else
    widget_detail="omarchy-shell / quickshell is not running for this user"
fi

echo ""
case "$widget_status" in
    enabled)
        ui_log_ok "oma-server installation complete (bar widget enabled)."
        ;;
    failed)
        ui_log_fail "oma-server files installed, but enabling the bar widget FAILED (exit ${enable_rc}): ${widget_detail:-no output}" \
            "From a terminal inside the desktop session run: omarchy plugin enable rohirik.oma-server --section right"
        ui_log_info "Verify status dashboard : oma-server status"
        exit 1
        ;;
    *)
        ui_log_warn "oma-server files installed; bar widget NOT registered (${widget_detail})." \
            "From a terminal inside the desktop session run: omarchy plugin enable rohirik.oma-server --section right"
        ;;
esac
ui_log_info "Verify status dashboard : oma-server status"
ui_log_info "Preview transition plan : oma-server diff"
ui_log_info "Enable / place widget   : omarchy plugin enable rohirik.oma-server --section right"
