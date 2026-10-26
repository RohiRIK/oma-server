#!/usr/bin/env bash
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
