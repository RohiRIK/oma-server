#!/usr/bin/env -S bash -p
# bash -p: never import exported functions (BASH_FUNC_*%%), BASH_ENV, ENV or SHELLOPTS.
# Re-exec under bash -p when started as `bash file` (omarchy-hook runs hooks that way),
# so exported functions/SHELLOPTS from the caller are dropped here as well. Skipped
# when sourced (BASH_SOURCE != $0), so it never replaces the caller's shell.
[[ "${BASH_SOURCE[0]}" != "$0" || $- == *p* ]] || exec /usr/bin/env -S bash -p -- "$0" "$@"
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
# OMA_SERVER_TEST_ROOT is test-only (same guard as lib/deep.sh).
if [[ -n "$DEEP_ROOT_PREFIX" ]]; then
    [[ "${OMA_SERVER_TEST_MODE:-}" == 1 ]] || { echo "OMA_SERVER_TEST_ROOT is test-only (set OMA_SERVER_TEST_MODE=1)" >&2; exit 2; }
    [[ "$(id -u)" -ne 0 ]] || { echo "OMA_SERVER_TEST_ROOT refused as root" >&2; exit 2; }
    [[ "$DEEP_ROOT_PREFIX" == /* && -d "$DEEP_ROOT_PREFIX" \
       && "$(realpath -e -- "$DEEP_ROOT_PREFIX" 2>/dev/null)" == "$DEEP_ROOT_PREFIX" \
       && "$(stat -c %u -- "$DEEP_ROOT_PREFIX" 2>/dev/null)" == "$(id -u)" ]] || {
        echo "OMA_SERVER_TEST_ROOT must be a real, user-owned absolute dir" >&2; exit 2; }
    for b in sudo pkexec; do
        t=$(type -t "$b" 2>/dev/null || true)
        [[ -z "$t" ]] && continue
        [[ "$t" == file ]] || { echo "OMA_SERVER_TEST_ROOT refused: $b is a $t" >&2; exit 2; }
        r=$(realpath -e -- "$(type -P "$b")" 2>/dev/null) || { echo "OMA_SERVER_TEST_ROOT refused: $b unresolvable" >&2; exit 2; }
        if [[ -u "$r" || -g "$r" || "$(stat -c %u -- "$r" 2>/dev/null)" == 0 ]]; then
            echo "OMA_SERVER_TEST_ROOT refused: real $b reachable ($r)" >&2; exit 2
        fi
    done
fi
# Never let an inherited shell function (BASH_FUNC_sudo%%) stand in for sudo/pkexec.
unset -f sudo pkexec 2>/dev/null || true
DEEP_HELPER_PATH="${DEEP_ROOT_PREFIX}/usr/local/lib/oma-server/deep-helper"
DEEP_HELPER_DIR="${DEEP_HELPER_PATH%/*}"
# /etc/sudoers.d is root-only (0750), so the rule itself cannot be seen. Detect the
# install by the helper/dir or by the grant showing up in 'sudo -n -l -l'.
# 'sudo -n -l' (no command) also lists an orphaned rule whose helper is gone.
DEEP_SUDOERS_PATH="${DEEP_ROOT_PREFIX}/etc/sudoers.d/oma-server-deep"
deep_installed="false"
deep_rule_unknown="false"
if [[ -e "$DEEP_HELPER_PATH" || -d "$DEEP_HELPER_DIR" ]]; then
    deep_installed="true"
elif command -v sudo >/dev/null 2>&1; then
    if sudo -n -l -l "$DEEP_HELPER_PATH" check 2>/dev/null | grep -q '!authenticate'; then
        deep_installed="true"
    elif sudo_list=$(sudo -n -l 2>/dev/null); then
        if printf "%s\n" "$sudo_list" | grep -qF -- "$DEEP_HELPER_PATH"; then
            deep_installed="true"
        fi
    else
        deep_rule_unknown="true"
    fi
fi
if [[ -f "$DEEP_STATE_FILE" ]]; then
    printf "[ FAIL ] Deep Server Mode is active (%s). Run 'oma-server disable' first; nothing was removed.\n" "$DEEP_STATE_FILE" >&2
    exit 1
fi
if [[ "$deep_installed" == "true" ]]; then
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

if [[ "$deep_installed" != "true" && "$deep_rule_unknown" == "true" ]]; then
    printf "[ WARN ] Could not check for a leftover Deep Server Mode sudoers rule without a password.\n" >&2
    printf "         If you ever ran 'oma-server deep-setup', remove it with: sudo rm -f %s\n" "$DEEP_SUDOERS_PATH" >&2
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
# Remove the opt-in deep console block (`oma-server deep-shell`) from login profiles.
# An interrupted rewrite never leaves its temp file behind.
UNINSTALL_TMP=""
for sig in INT TERM HUP; do
    # shellcheck disable=SC2064  # expand $sig now; $UNINSTALL_TMP at signal time
    trap "[[ -n \"\$UNINSTALL_TMP\" ]] && rm -f -- \"\$UNINSTALL_TMP\"; trap - $sig; kill -s $sig \$\$" "$sig"
done
for prof in "$HOME/.bash_profile" "${ZDOTDIR:-$HOME}/.zprofile"; do
    [[ -f "$prof" && ! -L "$prof" ]] || continue
    grep -qF "# >>> oma-server deep shell >>>" "$prof" || continue
    # L2: rewrite only when every begin marker is followed by its end marker; a
    # hand-edited, unterminated block would otherwise truncate the profile to EOF.
    if ! awk '$0=="# >>> oma-server deep shell >>>"{if(o)bad=1;o=1;n++;next} $0=="# <<< oma-server deep shell <<<"{if(!o)bad=1;o=0;next} END{exit (bad||o||n==0)?1:0}' "$prof"; then
        ui_log_warn "$prof has an oma-server deep shell block without a matching end marker; left it untouched. Remove it by hand."
        continue
    fi
    tmp=$(mktemp "${prof}.XXXXXX")
    UNINSTALL_TMP="$tmp"
    if awk '$0=="# >>> oma-server deep shell >>>"{h=0;s=1;next} $0=="# <<< oma-server deep shell <<<"{s=0;next} s{next} h{print "";h=0} $0==""{h=1;next} {print} END{if(h)print ""}' "$prof" > "$tmp"; then
        chmod --reference="$prof" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$prof" || rm -f "$tmp"
        UNINSTALL_TMP=""
    else
        rm -f "$tmp"
        UNINSTALL_TMP=""
        continue
    fi
    ui_log_info "Removed the deep console block from $prof"
done
trap - INT TERM HUP
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
