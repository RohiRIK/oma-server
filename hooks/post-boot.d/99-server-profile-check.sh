#!/usr/bin/env -S bash -p
# bash -p: never import exported functions (BASH_FUNC_*%%), BASH_ENV, ENV or SHELLOPTS.
# Re-exec under bash -p when started as `bash file` (omarchy-hook runs hooks that way),
# so exported functions/SHELLOPTS from the caller are dropped here as well. Skipped
# when sourced (BASH_SOURCE != $0), so it never replaces the caller's shell.
[[ "${BASH_SOURCE[0]}" != "$0" || $- == *p* ]] || exec /usr/bin/env -S bash -p -- "$0" "$@"
# ~/.config/omarchy/hooks/post-boot.d/99-server-profile-check.sh
# Post-boot and session recovery hook for oma-server (Omarchy Server-Mode).
# Guarantees that any unexpected reboot, crash, or session restart cleanly
# resets ephemeral locks, resumes suspended processes, and restores HOST_LAPTOP mode.
set -euo pipefail

CURRENT_UID="${UID:-$(id -u)}"
if ! [[ "$CURRENT_UID" =~ ^[0-9]+$ ]] || (( CURRENT_UID == 0 )); then
    exit 0
fi

RUN_DIR="/run/user/${CURRENT_UID}/omarchy-server-mode"

# --- Deep Server Mode -------------------------------------------------------
# This hook fires ~2s after Hyprland starts, i.e. also in the middle of a deep
# exit. While the exit runs (state DEEP_EXITING or deep.lock held) it owns all
# cleanup, so do nothing at all. Otherwise (root backup timer, reboot, or a manual
# login after DEEP_DEGRADED) let the CLI reconcile/finish the exit.
DEEP_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oma-server"
if [[ -f "$DEEP_DIR/deep.json" && ! -L "$DEEP_DIR/deep.json" ]]; then
    deep_state=$(jq -r '.state // ""' "$DEEP_DIR/deep.json" 2>/dev/null || true)
    if [[ "$deep_state" == "DEEP_EXITING" || "$deep_state" == "DEEP_ENTERING" ]]; then
        exit 0
    fi
    if [[ -f "$DEEP_DIR/deep.lock" ]] && ! flock -n "$DEEP_DIR/deep.lock" true 2>/dev/null; then
        exit 0
    fi
    oma_cli="$(command -v oma-server 2>/dev/null || true)"
    [[ -z "$oma_cli" && -x "$HOME/.local/bin/oma-server" ]] && oma_cli="$HOME/.local/bin/oma-server"
    if [[ -n "$oma_cli" ]]; then
        # Reconciles a boot_id change (reboot) and finishes DEEP_SERVER/DEEP_DEGRADED exits.
        # Run it outside the session cgroup so that stopping/restarting session units
        # can never take this cleanup (or the fresh session) down with it.
        # Unique unit per boot and run (a leftover failed unit can never block the name),
        # and clear old failed ones first.
        boot_tag=$(tr -dc '0-9a-f' < /proc/sys/kernel/random/boot_id 2>/dev/null | head -c 8 || true)
        postboot_unit="oma-server-deep-postboot-${boot_tag:-noboot}-$(date +%s)-$$"
        if command -v systemd-run >/dev/null 2>&1; then
            systemctl --user reset-failed 'oma-server-deep-postboot*' >/dev/null 2>&1 || true
        fi
        if command -v systemd-run >/dev/null 2>&1 && \
           systemd-run --user --quiet --collect --unit="$postboot_unit" \
               "$oma_cli" __deep-post-boot >/dev/null 2>&1; then
            :
        else
            "$oma_cli" __deep-post-boot >/dev/null 2>&1 || true
        fi
    fi
    exit 0
fi

_verify_and_terminate_pid() {
    local pid_file="$1"
    local pattern="$2"

    if [[ -f "$pid_file" && ! -L "$pid_file" ]]; then
        local pid=""
        pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) && [[ -d "/proc/$pid" && -O "/proc/$pid" ]]; then
            local comm="" cmdline=""
            comm=$(tr -d '\000\n' < "/proc/$pid/comm" 2>/dev/null || true)
            cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
            if [[ "$comm" =~ $pattern || "$cmdline" =~ $pattern ]]; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        fi
    fi
}

needs_recovery="false"

if [[ -d "$RUN_DIR" && ! -L "$RUN_DIR" && -O "$RUN_DIR" ]]; then
    needs_recovery="true"
    _verify_and_terminate_pid "$RUN_DIR/inhibitor.pid" "systemd-inhibit|sleep"
    _verify_and_terminate_pid "$RUN_DIR/timeout.pid" "oma-server|omarchy-server|bash|sleep"
    rm -rf "$RUN_DIR"
fi

if command -v systemctl >/dev/null 2>&1; then
    for unit in oma-server-inhibitor.service oma-server-timer.service; do
        if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            needs_recovery="true"
            systemctl --user stop "$unit" >/dev/null 2>&1 || true
        fi
    done
fi

# Check if any Quickshell instance is currently in Stopped (T) state
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    state=$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
    if [[ "$state" == "T" ]]; then
        needs_recovery="true"
        kill -CONT "$pid" 2>/dev/null || true
    fi
done < <(pgrep -u "$CURRENT_UID" -x "quickshell" 2>/dev/null || true)

if [[ "$needs_recovery" != "true" ]]; then
    exit 0
fi

# Re-synchronize Hyprland with bounded timeout when recovering from interrupted Homelab state
if command -v hyprctl >/dev/null 2>&1; then
    _run_hypr() {
        if command -v timeout >/dev/null 2>&1; then
            timeout -k 2 5s "$@" 2>/dev/null || true
        else
            "$@" 2>/dev/null || true
        fi
    }
    dpms_out="$(_run_hypr hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })')"
    if [[ "$dpms_out" != *"ok"* ]]; then
        _run_hypr hyprctl dispatch dpms on >/dev/null
    fi
    _run_hypr hyprctl reload >/dev/null
fi
