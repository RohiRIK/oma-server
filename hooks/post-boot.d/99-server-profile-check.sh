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

if [[ -d "$RUN_DIR" && ! -L "$RUN_DIR" && -O "$RUN_DIR" ]]; then
    _verify_and_terminate_pid "$RUN_DIR/inhibitor.pid" "systemd-inhibit|sleep"
    _verify_and_terminate_pid "$RUN_DIR/timeout.pid" "oma-server|omarchy-server|bash|sleep"
    rm -rf "$RUN_DIR"
fi

# Ensure any suspended Quickshell instance is resumed
pkill -CONT -u "$CURRENT_UID" -x "quickshell" 2>/dev/null || true
pkill -CONT -u "$CURRENT_UID" -x "omarchy-shell" 2>/dev/null || true

# Re-synchronize Hyprland with bounded timeout to guarantee normal desktop look & feel
if command -v hyprctl >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 2 3s hyprctl dispatch dpms on >/dev/null 2>&1 || true
        timeout -k 2 3s hyprctl reload >/dev/null 2>&1 || true
    else
        hyprctl dispatch dpms on >/dev/null 2>&1 || true
        hyprctl reload >/dev/null 2>&1 || true
    fi
fi
