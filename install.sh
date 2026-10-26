#!/usr/bin/env bash
# install.sh - Production installer for oma-server on Omarchy Linux systems.
# Enforces pre-flight validation, safe file permissions, and zero-emoji status badges.
set -euo pipefail

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
mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$BIN_DIR" "$HOOK_DIR"

# 2. Install modular libraries and CLI coordinator
cp -f "$SCRIPT_DIR/lib/ui.sh" \
      "$SCRIPT_DIR/lib/config.sh" \
      "$SCRIPT_DIR/lib/snapshot.sh" \
      "$SCRIPT_DIR/lib/transition.sh" \
      "$TARGET_DIR/lib/"
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
CURRENT_UID="${UID:-$(id -u)}"
if pgrep -u "$CURRENT_UID" -x "quickshell" >/dev/null 2>&1; then
    pkill -CONT -u "$CURRENT_UID" -x "quickshell" 2>/dev/null || true
    # Wait briefly for Quickshell's 150ms localPluginReloadTimer debounce to settle
    sleep 0.4
    if command -v omarchy-restart-shell >/dev/null 2>&1; then
        ui_log_info "Reloading omarchy-shell QML type cache..."
        if ! omarchy-restart-shell >/dev/null 2>&1; then
            omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
            sleep 0.6
        fi
    elif command -v omarchy-shell >/dev/null 2>&1; then
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        sleep 0.6
    fi
    if command -v omarchy >/dev/null 2>&1; then
        OMARCHY_SHELL_IPC_TIMEOUT=5s omarchy plugin enable rohirik.oma-server --section right >/dev/null 2>&1 || true
        sleep 0.4
    fi
fi

echo ""
ui_log_ok "oma-server installation complete."
ui_log_info "Verify status dashboard : oma-server status"
ui_log_info "Preview transition plan : oma-server diff"
ui_log_info "Enable / place widget   : omarchy plugin enable rohirik.oma-server --section right"
