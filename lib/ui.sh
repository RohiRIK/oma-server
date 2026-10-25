#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/ui.sh
# Deterministic TUI/CLI rendering engine for oma-server.
# Enforces a strict Zero-Emoji Policy using ANSI color hierarchies,
# Unicode box-drawing borders, Braille spinners, and bracketed status badges.
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Terminal Capability & ANSI Color Hierarchy Detection
# -----------------------------------------------------------------------------
UI_IS_TTY=false
if [[ -t 1 ]]; then
    UI_IS_TTY=true
fi

if [[ "$UI_IS_TTY" == true && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    readonly UI_RESET=$'\033[0m'
    readonly UI_BOLD=$'\033[1m'
    readonly UI_DIM=$'\033[2m'
    readonly UI_RED=$'\033[38;5;203m'
    readonly UI_GREEN=$'\033[38;5;78m'
    readonly UI_YELLOW=$'\033[38;5;221m'
    readonly UI_BLUE=$'\033[38;5;75m'
    readonly UI_MAGENTA=$'\033[38;5;177m'
    readonly UI_CYAN=$'\033[38;5;81m'
    readonly UI_WHITE=$'\033[38;5;255m'
    readonly UI_MUTED=$'\033[38;5;244m'
else
    readonly UI_RESET=""
    readonly UI_BOLD=""
    readonly UI_DIM=""
    readonly UI_RED=""
    readonly UI_GREEN=""
    readonly UI_YELLOW=""
    readonly UI_BLUE=""
    readonly UI_MAGENTA=""
    readonly UI_CYAN=""
    readonly UI_WHITE=""
    readonly UI_MUTED=""
fi

readonly -a UI_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# -----------------------------------------------------------------------------
# 2. Standardized High-Contrast Status Badges
# -----------------------------------------------------------------------------
ui_badge_ok()      { printf "%s[ OK ]%s"      "${UI_BOLD}${UI_GREEN}"   "${UI_RESET}"; }
ui_badge_info()    { printf "%s[ INFO ]%s"    "${UI_BOLD}${UI_BLUE}"    "${UI_RESET}"; }
ui_badge_sync()    { printf "%s[ SYNCING ]%s" "${UI_BOLD}${UI_MAGENTA}" "${UI_RESET}"; }
ui_badge_warn()    { printf "%s[ WARN ]%s"    "${UI_BOLD}${UI_YELLOW}"  "${UI_RESET}"; }
ui_badge_fail()    { printf "%s[ FAIL ]%s"    "${UI_BOLD}${UI_RED}"     "${UI_RESET}"; }
ui_badge_protect() { printf "%s[ GUARDED ]%s" "${UI_BOLD}${UI_CYAN}"    "${UI_RESET}"; }
ui_badge_idle()    { printf "%s[ STANDBY ]%s" "${UI_DIM}${UI_MUTED}"    "${UI_RESET}"; }

ui_log_ok() {
    local msg="$1"
    printf "%s %s%s%s\n" "$(ui_badge_ok)" "${UI_WHITE}" "$msg" "${UI_RESET}"
}

ui_log_info() {
    local msg="$1"
    printf "%s %s%s%s\n" "$(ui_badge_info)" "${UI_WHITE}" "$msg" "${UI_RESET}"
}

ui_log_sync() {
    local msg="$1"
    printf "%s %s%s%s\n" "$(ui_badge_sync)" "${UI_WHITE}" "$msg" "${UI_RESET}"
}

ui_log_warn() {
    local msg="$1"
    local hint="${2:-}"
    printf "%s %s%s%s\n" "$(ui_badge_warn)" "${UI_YELLOW}" "$msg" "${UI_RESET}" >&2
    if [[ -n "$hint" ]]; then
        printf "         %s└─ Recovery Hint:%s %s\n" "${UI_MUTED}" "${UI_RESET}" "$hint" >&2
    fi
}

ui_log_fail() {
    local msg="$1"
    local hint="${2:-}"
    printf "%s %s%s%s\n" "$(ui_badge_fail)" "${UI_RED}" "$msg" "${UI_RESET}" >&2
    if [[ -n "$hint" ]]; then
        printf "       %s└─ Recovery Hint:%s %s\n" "${UI_MUTED}" "${UI_RESET}" "$hint" >&2
    fi
}

# -----------------------------------------------------------------------------
# 3. Elapsed Time & Progress Bar Formatting
# -----------------------------------------------------------------------------
ui_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local sec="${EPOCHREALTIME%.*}"
        local frac="${EPOCHREALTIME#*.}"
        frac="${frac:0:3}"
        while (( ${#frac} < 3 )); do frac="${frac}0"; done
        printf "%d" "$(( sec * 1000 + 10#$frac ))"
    else
        date +%s000
    fi
}

ui_format_elapsed_ms() {
    local start_ms="$1"
    local end_ms="${2:-$(ui_now_ms)}"
    local delta=$(( end_ms - start_ms ))
    (( delta < 0 )) && delta=0
    local secs=$(( delta / 1000 ))
    local tenths=$(( (delta % 1000) / 100 ))
    printf "%d.%ds" "$secs" "$tenths"
}

ui_format_duration_human() {
    local total_sec="${1:-0}"
    if ! [[ "$total_sec" =~ ^[0-9]+$ ]]; then
        total_sec=0
    fi
    local hrs=$(( total_sec / 3600 ))
    local mins=$(( (total_sec % 3600) / 60 ))
    local secs=$(( total_sec % 60 ))
    printf "%02dh %02dm %02ds" "$hrs" "$mins" "$secs"
}

ui_render_bar_str() {
    local current="$1"
    local total="$2"
    local width="${3:-10}"
    (( total <= 0 )) && total=1
    (( current > total )) && current="$total"
    (( current < 0 )) && current=0

    local filled=$(( (current * width) / total ))
    local empty=$(( width - filled ))
    local pct=$(( (current * 100) / total ))

    local bar_fill=""
    local bar_empty=""
    local i
    for (( i = 0; i < filled; i++ )); do bar_fill+="█"; done
    for (( i = 0; i < empty; i++ )); do bar_empty+="░"; done

    printf "[%s%s%s%s%s] %3d%%" "${UI_CYAN}" "$bar_fill" "${UI_MUTED}" "$bar_empty" "${UI_RESET}" "$pct"
}

# Executes a command step with live Braille spinner, progress bar, and elapsed timer
ui_run_step() {
    local step_idx="$1"
    local step_total="$2"
    local label="$3"
    shift 3

    local start_ms
    start_ms="$(ui_now_ms)"
    local bar_prefix
    bar_prefix="$(ui_render_bar_str "$step_idx" "$step_total" 10)"

    if [[ "$UI_IS_TTY" == true ]]; then
        local frame_idx=0
        local spin_char="${UI_SPINNER_FRAMES[0]}"
        printf "\r\033[K  %s │ %s%s%s %s %s %s(0.0s)%s" \
            "$bar_prefix" "${UI_CYAN}" "$spin_char" "${UI_RESET}" \
            "$(ui_badge_sync)" "$label" "${UI_MUTED}" "${UI_RESET}"
    fi

    if "$@"; then
        local elapsed
        elapsed="$(ui_format_elapsed_ms "$start_ms")"
        local done_bar
        done_bar="$(ui_render_bar_str "$step_idx" "$step_total" 10)"
        if [[ "$UI_IS_TTY" == true ]]; then
            printf "\r\033[K  %s │ %s◆%s %s %-44s %s[%s]%s\n" \
                "$done_bar" "${UI_GREEN}" "${UI_RESET}" \
                "$(ui_badge_ok)" "$label" "${UI_MUTED}" "$elapsed" "${UI_RESET}"
        else
            printf "  %s %s (%s)\n" "$(ui_badge_ok)" "$label" "$elapsed"
        fi
        return 0
    else
        local rc=$?
        local elapsed
        elapsed="$(ui_format_elapsed_ms "$start_ms")"
        if [[ "$UI_IS_TTY" == true ]]; then
            printf "\r\033[K  %s │ %s◆%s %s %-44s %s[%s]%s\n" \
                "$bar_prefix" "${UI_RED}" "${UI_RESET}" \
                "$(ui_badge_fail)" "$label" "${UI_MUTED}" "$elapsed" "${UI_RESET}" >&2
        else
            printf "  %s %s (%s)\n" "$(ui_badge_fail)" "$label" "$elapsed" >&2
        fi
        return "$rc"
    fi
}

# -----------------------------------------------------------------------------
# 4. Structured Box-Drawing Dashboard Panels
# -----------------------------------------------------------------------------
# Repeating horizontal rule helper
ui_hr() {
    local count="$1"
    local char="${2:-─}"
    local out=""
    local i
    for (( i = 0; i < count; i++ )); do out+="$char"; done
    printf "%s" "$out"
}

ui_render_status_panel() {
    local mode="$1"
    local is_homelab="$2"
    local since_str="$3"
    local elapsed_human="$4"
    local in_status="$5"
    local timeout_status="$6"
    local dpms_status="$7"
    local qs_status="$8"
    local runtime_dir="$9"
    local protected_summary="${10:-0/0 active}"
    local health="${11:-OK}"

    local w=76
    local top_border="┌$(ui_hr "$w" "─")┐"
    local mid_border="├$(ui_hr "$w" "─")┤"
    local bot_border="└$(ui_hr "$w" "─")┘"

    local mode_badge
    if [[ "$is_homelab" == "true" ]]; then
        if [[ "$health" == "DEGRADED" ]]; then
            mode_badge="$(ui_badge_warn) HOMELAB_MODE (DEGRADED)"
        else
            mode_badge="$(ui_badge_ok) HOMELAB_MODE (ACTIVE)"
        fi
    else
        mode_badge="$(ui_badge_info) HOST_LAPTOP (DEFAULT PROFILE)"
    fi

    local in_badge
    if [[ "$in_status" == Active* ]]; then
        in_badge="$(ui_badge_ok)"
    elif [[ "$in_status" == "Stale" ]]; then
        in_badge="$(ui_badge_warn)"
    else
        in_badge="$(ui_badge_idle)"
    fi

    local dpms_badge
    if [[ "$dpms_status" == "OFF (Power Saving)" ]]; then
        dpms_badge="$(ui_badge_ok)"
    else
        dpms_badge="$(ui_badge_info)"
    fi

    local qs_badge
    if [[ "$qs_status" == Suspended* ]]; then
        qs_badge="$(ui_badge_ok)"
    elif [[ "$qs_status" == Running* ]]; then
        qs_badge="$(ui_badge_info)"
    else
        qs_badge="$(ui_badge_warn)"
    fi

    local tm_badge
    if [[ "$timeout_status" == Active* ]]; then
        tm_badge="$(ui_badge_ok)"
    else
        tm_badge="$(ui_badge_idle)"
    fi

    printf "\n%s%s%s\n" "${UI_CYAN}" "$top_border" "${UI_RESET}"
    printf "%s│%s  %sOMA-SERVER // SYSTEM TELEMETRY & GUARDRAIL DASHBOARD%s%*s%s│%s\n" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}${UI_WHITE}" "${UI_RESET}" 22 "" "${UI_CYAN}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$mid_border" "${UI_RESET}"

    printf "%s│%s  %-22s : %s\n" "${UI_CYAN}" "${UI_RESET}" "OPERATIONAL PROFILE" "$mode_badge"
    printf "%s│%s  %-22s : %s%s%s\n" "${UI_CYAN}" "${UI_RESET}" "ACTIVE SINCE" "${UI_WHITE}" "${since_str:-N/A (Host Mode)}" "${UI_RESET}"
    printf "%s│%s  %-22s : %s%s%s\n" "${UI_CYAN}" "${UI_RESET}" "SESSION ELAPSED" "${UI_CYAN}" "${elapsed_human:-00h 00m 00s}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$mid_border" "${UI_RESET}"

    printf "%s│%s  %sSUBSYSTEM GUARDRAILS%s\n" "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}${UI_MUTED}" "${UI_RESET}"
    printf "%s│%s  %-22s : %s %s\n" "${UI_CYAN}" "${UI_RESET}" "Power / Lid Inhibit" "$in_badge" "$in_status"
    printf "%s│%s  %-22s : %s %s\n" "${UI_CYAN}" "${UI_RESET}" "Display Output (DPMS)" "$dpms_badge" "$dpms_status"
    printf "%s│%s  %-22s : %s %s\n" "${UI_CYAN}" "${UI_RESET}" "Quickshell Event Loop" "$qs_badge" "$qs_status"
    printf "%s│%s  %-22s : %s %s\n" "${UI_CYAN}" "${UI_RESET}" "Dead-Man Timer Guard" "$tm_badge" "$timeout_status"
    printf "%s│%s  %-22s : %s %s\n" "${UI_CYAN}" "${UI_RESET}" "Tier-0 Protected Units" "$(ui_badge_protect)" "$protected_summary"
    printf "%s│%s  %-22s : %s%s%s\n" "${UI_CYAN}" "${UI_RESET}" "Ephemeral Runtime Dir" "${UI_MUTED}" "${runtime_dir:-None (Clean)}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$bot_border" "${UI_RESET}"
}

ui_render_diff_panel() {
    local snapshot_json="$1"
    local timeout_val="${2:-}"
    shift 2
    local -a services=("$@")

    local cur_anim cur_blur cur_shadow cur_vfr cur_dpms
    cur_anim=$(echo "$snapshot_json" | jq -r '.compositor_properties["animations:enabled"]')
    cur_blur=$(echo "$snapshot_json" | jq -r '.compositor_properties["decoration:blur:enabled"]')
    cur_shadow=$(echo "$snapshot_json" | jq -r '.compositor_properties["decoration:drop_shadow"]')
    cur_vfr=$(echo "$snapshot_json" | jq -r '.compositor_properties["misc:vfr"]')
    cur_dpms=$(echo "$snapshot_json" | jq -r '.compositor_properties.dpms_status')

    local qs_pid qs_running qs_action
    qs_pid=$(echo "$snapshot_json" | jq -r '.quickshell_state.pid')
    qs_running=$(echo "$snapshot_json" | jq -r '.quickshell_state.was_running')
    qs_action=$(echo "$snapshot_json" | jq -r '.quickshell_state.action_taken')

    local qs_desc="Inactive"
    if [[ "$qs_running" == "true" ]]; then
        qs_desc="Running (PID: $qs_pid)"
    fi

    local dpms_desc="OFF"
    if [[ "$cur_dpms" == "true" ]]; then
        dpms_desc="ON (Active)"
    fi

    local timeout_desc="Disabled (Manual Restore)"
    if [[ -n "$timeout_val" && "$timeout_val" != "0" ]]; then
        timeout_desc="$timeout_val (Auto-Revert)"
    fi

    local c1=28 c2=22 c3=26
    local top="┌$(ui_hr "$c1")┬$(ui_hr "$c2")┬$(ui_hr "$c3")┐"
    local sep="├$(ui_hr "$c1")┼$(ui_hr "$c2")┼$(ui_hr "$c3")┤"
    local bot="└$(ui_hr "$c1")┴$(ui_hr "$c2")┴$(ui_hr "$c3")┘"
    local full_w=$(( c1 + c2 + c3 + 2 ))
    local banner_top="┌$(ui_hr "$full_w")┐"
    local banner_mid="├$(ui_hr "$c1")┬$(ui_hr "$c2")┬$(ui_hr "$c3")┤"

    printf "\n%s%s%s\n" "${UI_CYAN}" "$banner_top" "${UI_RESET}"
    printf "%s│%s  %sOMA-SERVER // TRANSITION PLANNER (HOST_LAPTOP -> HOMELAB_MODE)%s%*s%s│%s\n" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}${UI_WHITE}" "${UI_RESET}" 14 "" "${UI_CYAN}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$banner_mid" "${UI_RESET}"
    printf "%s│%s %s%-26s%s %s│%s %s%-20s%s %s│%s %s%-24s%s %s│%s\n" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}" "SUBSYSTEM / PROPERTY" "${UI_RESET}" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}" "CURRENT HOST STATE" "${UI_RESET}" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}" "TARGET HOMELAB STATE" "${UI_RESET}" \
        "${UI_CYAN}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$sep" "${UI_RESET}"

    local -a rows=(
        "animations:enabled|${cur_anim}|0 (Disabled)"
        "decoration:blur:enabled|${cur_blur}|false (Disabled)"
        "decoration:drop_shadow|${cur_shadow}|false (Disabled)"
        "misc:vfr|${cur_vfr}|1 (Enforced VFR)"
        "display:dpms|${dpms_desc}|OFF (Panel Powerdown)"
        "omarchy-shell (Quickshell)|${qs_desc}|${qs_action} (0% CPU Pause)"
        "systemd-logind inhibitor|Inactive|Active (Sleep/Lid Lock)"
        "dead-man switch timer|None|${timeout_desc}"
    )

    local row prop cur target
    for row in "${rows[@]}"; do
        IFS='|' read -r prop cur target <<< "$row"
        printf "%s│%s %-26s %s│%s %s%-20s%s %s│%s %s%-24s%s %s│%s\n" \
            "${UI_CYAN}" "${UI_RESET}" "$prop" \
            "${UI_CYAN}" "${UI_RESET}" "${UI_MUTED}" "${cur:0:20}" "${UI_RESET}" \
            "${UI_CYAN}" "${UI_RESET}" "${UI_GREEN}" "${target:0:24}" "${UI_RESET}" \
            "${UI_CYAN}" "${UI_RESET}"
    done
    printf "%s%s%s\n" "${UI_CYAN}" "$bot" "${UI_RESET}"

    # Tier-0 Protected Services Box
    local svc_top="┌$(ui_hr "$full_w")┐"
    local svc_sep="├$(ui_hr "$full_w")┤"
    local svc_bot="└$(ui_hr "$full_w")┘"
    printf "\n%s%s%s\n" "${UI_CYAN}" "$svc_top" "${UI_RESET}"
    printf "%s│%s  %sTIER-0 PROTECTED HOMELAB SERVICES AUDIT (GUARANTEED UNTOUCHED)%s%*s%s│%s\n" \
        "${UI_CYAN}" "${UI_RESET}" "${UI_BOLD}${UI_WHITE}" "${UI_RESET}" 14 "" "${UI_CYAN}" "${UI_RESET}"
    printf "%s%s%s\n" "${UI_CYAN}" "$svc_sep" "${UI_RESET}"

    local svc status
    for svc in "${services[@]}"; do
        [[ -z "$svc" ]] && continue
        status="inactive"
        if run_with_timeout 2 systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="active (system)"
        elif run_with_timeout 2 systemctl --user is-active --quiet "$svc" 2>/dev/null; then
            status="active (user)"
        fi

        if [[ "$status" != "inactive" ]]; then
            printf "%s│%s  %s %-28s %s│%s %-32s %s│%s\n" \
                "${UI_CYAN}" "${UI_RESET}" "$(ui_badge_protect)" "$svc" \
                "${UI_MUTED}" "${UI_RESET}" "${UI_GREEN}${status}${UI_RESET}" \
                "${UI_CYAN}" "${UI_RESET}"
        else
            printf "%s│%s  %s %-28s %s│%s %-32s %s│%s\n" \
                "${UI_CYAN}" "${UI_RESET}" "$(ui_badge_idle)" "$svc" \
                "${UI_MUTED}" "${UI_RESET}" "${UI_MUTED}inactive (no action)${UI_RESET}" \
                "${UI_CYAN}" "${UI_RESET}"
        fi
    done
    printf "%s%s%s\n" "${UI_CYAN}" "$svc_bot" "${UI_RESET}"
}
