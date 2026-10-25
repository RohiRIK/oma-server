#!/usr/bin/env bash
# ~/.config/omarchy/hooks/post-boot.d/99-server-profile-check.sh
# Post-boot recovery hook for oma-server (Omarchy Server-Mode)
# Guarantees that any unexpected reboot or power outage cleanly resets to HOST_LAPTOP mode.
set -euo pipefail

RUN_DIR="/run/user/${UID}/omarchy-server-mode"

# If an orphaned runtime directory or lock remains from a previous crash
if [[ -d "$RUN_DIR" ]]; then
    # Release any orphaned inhibitor processes
    if [[ -f "$RUN_DIR/inhibitor.pid" ]]; then
        in_pid=$(cat "$RUN_DIR/inhibitor.pid" 2>/dev/null || true)
        if [[ -n "$in_pid" ]] && kill -0 "$in_pid" 2>/dev/null; then
            kill -TERM "$in_pid" 2>/dev/null || true
        fi
    fi

    # Clean up stale locks and snapshots
    rm -rf "$RUN_DIR"
fi

# Re-synchronize Hyprland to ensure normal desktop look & feel (animations, blur, panels)
if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
fi
