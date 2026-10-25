#!/usr/bin/env bash
# ~/.config/omarchy/plugins/server-mode/lib/config.sh
# Input validation, schema sanitization, and bounded subprocess execution for oma-server.
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Subprocess Timeout Boundary
# -----------------------------------------------------------------------------
run_with_timeout() {
    local secs="$1"
    shift
    if ! [[ "$secs" =~ ^[0-9]+$ ]] || (( secs < 1 )); then
        secs=3
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 2 "${secs}s" "$@"
    else
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# 2. Environment & Ephemeral Runtime Directory Security Validation
# -----------------------------------------------------------------------------
validate_runtime_environment() {
    local current_uid="${UID:-$(id -u)}"
    if ! [[ "$current_uid" =~ ^[0-9]+$ ]]; then
        ui_log_fail "Unable to resolve numeric user UID." "Verify standard POSIX user session."
        return 1
    fi

    if (( current_uid == 0 )); then
        ui_log_fail "Refusing to execute oma-server as root (UID 0)." \
            "Run oma-server as your normal desktop session user."
        return 1
    fi

    local base_run="/run/user/${current_uid}"
    if [[ ! -d "$base_run" ]] || [[ -L "$base_run" ]] || [[ ! -O "$base_run" ]]; then
        ui_log_fail "Session runtime directory '$base_run' is missing, symlinked, or not owned by UID $current_uid." \
            "Ensure pam_systemd / systemd-logind user session is active."
        return 1
    fi

    return 0
}

ensure_secure_run_dir() {
    local run_dir="$1"

    if [[ -L "$run_dir" ]]; then
        ui_log_fail "Security violation: Runtime path '$run_dir' is a symbolic link." \
            "Remove the symlink and run 'oma-server rescue'."
        return 1
    fi

    mkdir -p "$run_dir"
    chmod 0700 "$run_dir"

    if [[ ! -O "$run_dir" ]]; then
        ui_log_fail "Security violation: Runtime directory '$run_dir' is not owned by current user." \
            "Run 'oma-server rescue' or inspect /run/user permissions."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# 3. CLI Input & Duration Schema Validation
# -----------------------------------------------------------------------------
# Converts a duration token (e.g. "45s", "30m", "2h", "1d", "120") into seconds.
# Bounds: 5 seconds minimum, 604800 seconds (7 days) maximum.
parse_and_validate_timeout() {
    local raw="${1:-}"
    if [[ -z "$raw" || "$raw" == "0" ]]; then
        printf "0"
        return 0
    fi

    if ! [[ "$raw" =~ ^([0-9]+)([smhdSMHD]?)$ ]]; then
        ui_log_fail "Invalid timeout specification '$raw'." \
            "Use positive integer with optional unit: e.g., 60s, 30m, 2h, 1d."
        return 1
    fi

    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2],,}"
    local total_sec=0

    case "$unit" in
        ""|"s") total_sec=$(( 10#$num )) ;;
        "m")    total_sec=$(( 10#$num * 60 )) ;;
        "h")    total_sec=$(( 10#$num * 3600 )) ;;
        "d")    total_sec=$(( 10#$num * 86400 )) ;;
        *)
            ui_log_fail "Unsupported duration unit in '$raw'." \
                "Supported units: s (seconds), m (minutes), h (hours), d (days)."
            return 1
            ;;
    esac

    if (( total_sec < 5 || total_sec > 604800 )); then
        ui_log_fail "Timeout '$raw' (${total_sec}s) is outside safe operating bounds (5s .. 7d)." \
            "Choose a duration between 5s and 7d (604800s)."
        return 1
    fi

    printf "%d" "$total_sec"
    return 0
}

# Validates systemd-inhibit --what colon-delimited token list
validate_inhibit_what() {
    local raw="${1:-}"
    local default_what="sleep:idle:handle-lid-switch"
    [[ -z "$raw" ]] && { printf "%s" "$default_what"; return 0; }

    local IFS=':'
    local -a tokens=()
    read -ra tokens <<< "$raw"
    local tok
    for tok in "${tokens[@]}"; do
        case "$tok" in
            sleep|idle|shutdown|handle-power-key|handle-suspend-key|handle-hibernate-key|handle-lid-switch)
                ;;
            *)
                printf "%s" "$default_what"
                return 0
                ;;
        esac
    done
    printf "%s" "$raw"
}

sanitize_label_string() {
    local raw="${1:-}"
    local fallback="${2:-Omarchy Homelab Workload Active}"
    # Strip control characters, quotes, backticks, dollar signs, and semicolons
    local clean
    clean=$(printf "%s" "$raw" | tr -d '\000-\037\177"`$;|\\' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    clean="${clean:0:120}"
    if [[ -z "$clean" ]]; then
        printf "%s" "$fallback"
    else
        printf "%s" "$clean"
    fi
}

# -----------------------------------------------------------------------------
# 4. Deterministic TOML Configuration Parser
# -----------------------------------------------------------------------------
# Reads a scalar key inside [section] from config.toml safely
config_get_scalar() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default_val="$4"

    if [[ ! -f "$file" ]] || [[ ! -r "$file" ]]; then
        printf "%s" "$default_val"
        return 0
    fi

    local raw_val
    raw_val=$(awk -v sec="[$section]" -v k="$key" '
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            in_sec = (line == sec)
            next
        }
        in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", $0)
            # Strip inline comments outside quotes
            if ($0 ~ /^"/) {
                sub(/^"/, "", $0)
                sub(/".*$/, "", $0)
            } else {
                sub(/[[:space:]]*#.*$/, "", $0)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            }
            print $0
            exit
        }
    ' "$file" 2>/dev/null || true)

    if [[ -z "$raw_val" ]]; then
        printf "%s" "$default_val"
    else
        printf "%s" "$raw_val"
    fi
}

config_get_bool() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default_val="$4"

    local val
    val="$(config_get_scalar "$file" "$section" "$key" "$default_val")"
    case "${val,,}" in
        true|1|yes)  printf "true" ;;
        false|0|no)  printf "false" ;;
        *)           printf "%s" "$default_val" ;;
    esac
}

# Extracts and strictly validates Tier-0 protected systemd service names
get_whitelist_services() {
    local config_file="${1:-}"
    local -a default_units=(
        "docker.service"
        "containerd.service"
        "podman.service"
        "tailscaled.service"
        "syncthing.service"
        "caddy.service"
        "nginx.service"
        "sshd.service"
        "pipewire.service"
        "wireplumber.service"
    )

    local -a extracted=()
    if [[ -n "$config_file" && -f "$config_file" && -r "$config_file" ]]; then
        while IFS= read -r candidate; do
            [[ -z "$candidate" ]] && continue
            if [[ "$candidate" =~ ^[a-zA-Z0-9@_.-]+\.(service|socket|target)$ ]]; then
                extracted+=("$candidate")
            fi
        done < <(
            awk '
                /^[[:space:]]*\[whitelist\][[:space:]]*$/ { in_sec=1; next }
                /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { in_sec=0 }
                in_sec {
                    line = $0
                    sub(/#.*/, "", line)
                    while (match(line, /"[^"]+"/)) {
                        tok = substr(line, RSTART + 1, RLENGTH - 2)
                        print tok
                        line = substr(line, RSTART + RLENGTH)
                    }
                }
            ' "$config_file" 2>/dev/null || true
        )
    fi

    if (( ${#extracted[@]} == 0 )); then
        printf "%s\n" "${default_units[@]}"
    else
        printf "%s\n" "${extracted[@]}"
    fi
}
