#!/usr/bin/env bash
# uninstall.sh - Safe uninstaller for oma-server on Omarchy Linux systems.
# Restores HOST_LAPTOP baseline before removing runtime artifacts, hooks, and bar widget.
set -euo pipefail

# omarchy-shell / omarchy-plugin-catalog need OMARCHY_PATH; it is only set inside
# the graphical session, so default it for plain SSH / non-login shells.
: "${OMARCHY_PATH:=/usr/share/omarchy}"
export OMARCHY_PATH

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/server-mode"
BIN_DIR="$HOME/.local/bin"
HOOK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks/post-boot.d/99-server-profile-check.sh"
SHELL_PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/rohirik.oma-server"
CURRENT_UID="${UID:-$(id -u)}"
RUN_DIR="${OMA_SERVER_RUN_DIR:-/run/user/${CURRENT_UID}/omarchy-server-mode}"
CONFIG_FILE="$TARGET_DIR/config.toml"

usage() {
    cat <<'USAGE'
Usage: ./uninstall.sh [--purge] [--help]

  (default)   Remove oma-server but KEEP your config.toml. When run from an
              interactive terminal you are asked first (default answer: keep).
  --purge     Remove everything, including config.toml, without asking.
  -h, --help  Show this help.
USAGE
}

PURGE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge) PURGE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf "[ FAIL ] Unknown option '%s'.\n" "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -f "$SCRIPT_DIR/lib/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/ui.sh"
else
    ui_log_info() { printf "[ INFO ] %s\n" "$1"; }
    ui_log_ok()   { printf "[ OK ] %s\n" "$1"; }
    ui_log_warn() { printf "[ WARN ] %s\n" "$1" >&2; }
fi

# 0. Deep Server Mode guard: never uninstall underneath an active deep session, and
#    remove the opt-in root helper + sudoers rule before the CLI that removes them.
DEEP_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/oma-server/deep.json"
DEEP_ROOT_PREFIX="${OMA_SERVER_TEST_ROOT:-}"
DEEP_HELPER_PATH="${DEEP_ROOT_PREFIX}/usr/local/lib/oma-server/deep-helper"
DEEP_SUDOERS_PATH="${DEEP_ROOT_PREFIX}/etc/sudoers.d/oma-server-deep"
if [[ -f "$DEEP_STATE_FILE" ]]; then
    printf "[ FAIL ] Deep Server Mode is active (%s). Run 'oma-server disable' first; nothing was removed.\n" "$DEEP_STATE_FILE" >&2
    exit 1
fi
if [[ -e "$DEEP_HELPER_PATH" || -e "$DEEP_SUDOERS_PATH" ]]; then
    deep_cli=""
    for cand in "$TARGET_DIR/bin/oma-server" "$SCRIPT_DIR/bin/oma-server"; do
        [[ -x "$cand" ]] && { deep_cli="$cand"; break; }
    done
    if [[ ! -t 0 || -z "$deep_cli" ]]; then
        printf "[ FAIL ] The Deep Server Mode root helper/sudoers rule is installed and removing it needs sudo in a terminal.\n" >&2
        printf "         Run 'oma-server deep-setup --remove' (e.g. via 'ssh -t'), then re-run ./uninstall.sh. Nothing was removed.\n" >&2
        exit 1
    fi
    if ! "$deep_cli" deep-setup --remove; then
        printf "[ FAIL ] Could not remove the Deep Server Mode helper; nothing else was removed.\n" >&2
        exit 1
    fi
fi

# Decide config.toml fate up front, before anything is removed.
KEEP_CONFIG="true"
if [[ "$PURGE" == "true" ]]; then
    KEEP_CONFIG="false"
elif [[ -f "$CONFIG_FILE" && -t 0 ]]; then
    reply=""
    read -r -p "Also delete your configuration ($CONFIG_FILE)? [y/N] " reply || reply=""
    if [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        KEEP_CONFIG="false"
    fi
fi

# 1. Restore HOST_LAPTOP profile if currently in HOMELAB_MODE (an active snapshot
#    exists); a bare or empty runtime dir is just removed silently.
if [[ -f "$RUN_DIR/active-snapshot.json" ]]; then
    ui_log_info "Active runtime state detected at $RUN_DIR; restoring HOST_LAPTOP baseline..."
    if [[ -x "$TARGET_DIR/bin/omarchy-server-mode" ]]; then
        "$TARGET_DIR/bin/omarchy-server-mode" disable >/dev/null 2>&1 || \
        "$TARGET_DIR/bin/omarchy-server-mode" rescue >/dev/null 2>&1 || true
    elif [[ -x "$SCRIPT_DIR/bin/oma-server" ]]; then
        "$SCRIPT_DIR/bin/oma-server" disable >/dev/null 2>&1 || \
        "$SCRIPT_DIR/bin/oma-server" rescue >/dev/null 2>&1 || true
    fi
    rm -rf "$RUN_DIR"
elif [[ -d "$RUN_DIR" && ! -L "$RUN_DIR" ]]; then
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
    if [[ "$KEEP_CONFIG" == "true" && -f "$CONFIG_FILE" ]]; then
        ui_log_info "Removing runtime files from: $TARGET_DIR (keeping config.toml)"
        find "$TARGET_DIR" -mindepth 1 -maxdepth 1 ! -name config.toml -exec rm -rf {} +
        ui_log_info "Configuration kept at: $CONFIG_FILE (run './uninstall.sh --purge' to remove it)"
    else
        ui_log_info "Removing runtime directory: $TARGET_DIR"
        rm -rf "$TARGET_DIR"
    fi
fi

if command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo ""
ui_log_ok "oma-server uninstallation complete."
