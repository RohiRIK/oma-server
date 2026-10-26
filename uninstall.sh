#!/usr/bin/env bash
# uninstall.sh - Safe uninstaller for oma-server on Omarchy Linux systems.
# Restores HOST_LAPTOP baseline before removing runtime artifacts, hooks, and bar widget.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/server-mode"
BIN_DIR="$HOME/.local/bin"
HOOK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks/post-boot.d/99-server-profile-check.sh"
SHELL_PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/rohirik.oma-server"
CURRENT_UID="${UID:-$(id -u)}"
RUN_DIR="/run/user/${CURRENT_UID}/omarchy-server-mode"

if [[ -f "$SCRIPT_DIR/lib/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/ui.sh"
else
    ui_log_info() { printf "[ INFO ] %s\n" "$1"; }
    ui_log_ok()   { printf "[ OK ] %s\n" "$1"; }
    ui_log_warn() { printf "[ WARN ] %s\n" "$1" >&2; }
fi

# 1. Restore HOST_LAPTOP profile if currently in HOMELAB_MODE
if [[ -d "$RUN_DIR" ]]; then
    ui_log_info "Active runtime state detected at $RUN_DIR; restoring HOST_LAPTOP baseline..."
    if [[ -x "$TARGET_DIR/bin/omarchy-server-mode" ]]; then
        "$TARGET_DIR/bin/omarchy-server-mode" disable >/dev/null 2>&1 || \
        "$TARGET_DIR/bin/omarchy-server-mode" rescue >/dev/null 2>&1 || true
    elif [[ -x "$SCRIPT_DIR/bin/oma-server" ]]; then
        "$SCRIPT_DIR/bin/oma-server" disable >/dev/null 2>&1 || \
        "$SCRIPT_DIR/bin/oma-server" rescue >/dev/null 2>&1 || true
    fi
    rm -rf "$RUN_DIR"
fi

# 2. Stop any transient systemd user units
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop oma-server-inhibitor.service oma-server-timer.service >/dev/null 2>&1 || true
fi

# 3. Disable Quickshell bar widget
if command -v omarchy >/dev/null 2>&1; then
    ui_log_info "Disabling Quickshell bar widget: rohirik.oma-server"
    OMARCHY_SHELL_IPC_TIMEOUT=5s omarchy plugin disable rohirik.oma-server >/dev/null 2>&1 || true
fi

# 4. Remove Quickshell plugin directory (preserve repo if symlinked via dev link)
if [[ -L "$SHELL_PLUGIN_DIR" ]]; then
    ui_log_info "Removing plugin symlink: $SHELL_PLUGIN_DIR"
    rm -f "$SHELL_PLUGIN_DIR"
elif [[ -d "$SHELL_PLUGIN_DIR" ]]; then
    if [[ "$(realpath "$SHELL_PLUGIN_DIR")" != "$(realpath "$SCRIPT_DIR")" ]]; then
        ui_log_info "Removing Quickshell plugin directory: $SHELL_PLUGIN_DIR"
        rm -rf "$SHELL_PLUGIN_DIR"
    fi
fi

# 5. Remove CLI symlinks, post-boot hook, and runtime directory
ui_log_info "Removing CLI symlinks from: $BIN_DIR"
rm -f "$BIN_DIR/oma-server" "$BIN_DIR/omarchy-server-mode"

if [[ -f "$HOOK_FILE" ]]; then
    ui_log_info "Removing post-boot hook: $HOOK_FILE"
    rm -f "$HOOK_FILE"
fi

if [[ -d "$TARGET_DIR" ]]; then
    ui_log_info "Removing runtime directory: $TARGET_DIR"
    rm -rf "$TARGET_DIR"
fi

if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo ""
ui_log_ok "oma-server uninstallation complete."
