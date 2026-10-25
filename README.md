<p align="center">
  <img src="assets/banner.png" alt="oma-server banner" width="100%">
</p>

<p align="center">
  <img src="assets/logo.png" alt="oma-server logo" width="110px"><br>
  <strong>Enterprise Performance &amp; Homelab Mode Orchestrator for Omarchy (Arch + Hyprland + Quickshell)</strong>
</p>

<p align="center">
  <a href="#origin--motivation">Origin &amp; Motivation</a> |
  <a href="#core-capabilities--guardrails">Capabilities</a> |
  <a href="#architecture--state-machine">Architecture</a> |
  <a href="#installation">Installation</a> |
  <a href="#quickshell-telemetry-panel">Panel UX</a> |
  <a href="#cli-reference">CLI Usage</a> |
  <a href="#configuration">Configuration</a>
</p>

---

## Origin & Motivation

> *"Interactive desktop ergonomics when at the keyboard; zero-overhead headless compute when operating remotely over SSH or running autonomous AI workloads."*

Omarchy delivers a modern Linux desktop experience powered by Hyprland and Quickshell. For interactive daily-driver work, blur shaders, fluid animations, status panels, and audio subsystems provide exceptional ergonomics.

However, a modern workstation frequently operates in two distinct roles:
1. **Interactive Workstation (`HOST_LAPTOP`)**: Low input latency, rich visual polish, and standard desktop power management.
2. **Compute Node / Agent Runner (`HOMELAB_MODE`)**: When stepping away, connecting over SSH, or running heavy unattended workloads (autonomous AI agents, container clusters, compilation pipelines, or media transcoding), the desktop GUI becomes unnecessary overhead.

Leaving full Hyprland compositing, physical displays, and bar polling active during remote compute sessions:
* **Wastes 15-30W of power** keeping physical display panels illuminated.
* **Consumes GPU memory bandwidth** and shader time computing window animations and multi-pass blurs.
* **Triggers power management sleep loops** on lid-close or idle timeouts, interrupting active SSH sessions and background jobs.

**`oma-server` eliminates this trade-off.** It transitions the system into a hardened, low-overhead homelab profile on demand and restores the full interactive Omarchy desktop in under a second.

---

## Core Capabilities & Guardrails

* **Tier-0 Core Service Protection**: Strict systemd unit validation guarantees that `docker`, `containerd`, `podman`, `tailscaled`, `syncthing`, `caddy`, `nginx`, `sshd`, `pipewire`, and `wireplumber` remain untouched during transitions.
* **Transactional Rollback Engine**: Every state mutation step is tracked; if any pre-flight or runtime step fails, `oma-server` automatically rolls back completed steps and restores the host baseline.
* **PID-Verified Process Signaling**: Inspects `/proc/<pid>/comm`, `/proc/<pid>/cmdline`, and UID ownership before issuing `SIGSTOP`, `SIGCONT`, or `SIGTERM`, preventing stale PID recycling hazards.
* **Non-Destructive Quickshell Pause**: Uses user-scoped `SIGSTOP` / `SIGCONT` to pause the shell event loop to 0 CPU ticks without tearing down memory maps, IPC sockets, or window state.
* **Panel Powerdown (DPMS Off)**: Powers down display outputs (`hyprctl dispatch dpms off`), saving 15-30W and reducing compositor passes to near zero.
* **Lid & Sleep Inhibit**: Spawns a detached, FD-isolated `systemd-inhibit` lock (`sleep:idle:handle-lid-switch`) so closing a laptop lid never halts running containers or SSH sessions.
* **Dead Man's Switch Timer**: Supports bounded `--timeout <duration>` (`5s` to `7d`, e.g. `oma-server enable --timeout 2h`) to automatically restore `HOST_LAPTOP` mode when unattended work finishes.
* **Zero Side-Effect Dry-Run**: `oma-server diff` and `oma-server enable --dry-run` evaluate compositor and service state strictly in memory.

---

## Architecture & State Machine

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          SYSTEM OPERATIONAL STATE                       │
├────────────────────────────────────┬────────────────────────────────────┤
│         HOST_LAPTOP PROFILE        │        HOMELAB_MODE PROFILE        │
│    (Latency & Ergonomics First)    │  (Throughput & Availability First) │
├────────────────────────────────────┼────────────────────────────────────┤
│ - Hyprland shaders & animations ON │ - Compositor throttled (VFR, 0 FX) │
│ - Omarchy Quickshell active        │ - Omarchy Quickshell paused (STOP) │
│ - Standard sleep/lid-close policy  │ - systemd sleep/lid inhibit active │
│ - Physical display outputs ON      │ - Displays DPMS OFF (power saved)  │
│ - Tier-0 services running baseline │ - Tier-0 services guarded          │
└────────────────────────────────────┴────────────────────────────────────┘
                   │                                    ▲
                   ▼                                    │
         [ oma-server enable ]                [ oma-server disable ]
     (Atomic Snapshot & Pre-Flight)         (Transactional Restoration)
```

---

## Installation

Clone the repository and execute the installer:

```bash
git clone https://github.com/RohiRIK/oma-server.git
cd oma-server
./install.sh
```

The installer performs pre-flight artifact validation and:
1. Installs the CLI coordinator and modular libraries (`ui.sh`, `config.sh`, `snapshot.sh`, `transition.sh`) into `~/.config/omarchy/plugins/server-mode/`.
2. Symlinks `oma-server` and `omarchy-server-mode` into `~/.local/bin/`.
3. Installs the post-boot safety recovery hook into `~/.config/omarchy/hooks/post-boot.d/99-server-profile-check.sh`.
4. Configures the Quickshell bar widget in `~/.config/omarchy/plugins/rohirik.oma-server/`.

To place the widget in the Omarchy status bar:
```bash
omarchy bar move rohirik.oma-server --section right
```

---

## Quickshell Telemetry Panel

`oma-server` ships with a native Quickshell bar widget (`Panel.qml`) featuring a zero-emoji, high-contrast telemetry interface:

<p align="center">
  <img src="preview.png" alt="Oma Server Panel Component Preview" width="85%">
</p>

* **Bar Indicator**: Displays `◇` in `HOST_LAPTOP` mode, `◆` with an active status indicator in `HOMELAB_MODE`, and an animated Braille spinner (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) during transitions.
* **Dashboard Popup**:
  * **Header & Status Badge**: High-contrast bracketed badges (`[ OK ]`, `[ INFO ]`, `[ SYNCING ]`, `[ WARN ]`, `[ FAIL ]`) and live session elapsed time.
  * **Dynamic Loader Banner**: Displays a Braille spinner, segmented progress bar (`[████████░░] 80%`), and live elapsed timer during state transitions.
  * **Subsystem Telemetry Matrix**: Box-drawn key-value table reporting Power/Lid Inhibit, Display DPMS, Quickshell Loop, Dead-Man Timer, and Tier-0 Whitelist counts.
  * **Dead Man's Switch Presets**: One-click timeout presets (`[ OFF ]`, `[ 30M ]`, `[ 1H ]`, `[ 2H ]`, `[ 4H ]`).
  * **Action Controls**: Mode toggle button, `[ DIFF ] PLAN` terminal launcher, `[ SYNC ] REFRESH`, and `[ RESCUE ] RESET` emergency recovery.

---

## CLI Reference

### 1. Inspect System Telemetry
```bash
# Box-drawn TUI telemetry dashboard
oma-server status

# Machine-readable JSON telemetry payload
oma-server status --json
```

### 2. Preview Transition Plan (Dry-Run)
```bash
# In-memory transition diff table and Tier-0 service audit
oma-server diff

# Full dry-run simulation with optional timeout preview
oma-server enable --dry-run --timeout 2h
```

### 3. Transition to Homelab Mode
```bash
# Interactive mode (renders diff plan and prompts for confirmation)
oma-server enable

# Non-interactive transition with 3-hour Dead Man's Switch auto-revert timer
oma-server enable --yes --timeout 3h
```

### 4. Restore Host / Laptop Desktop
```bash
oma-server disable
```
Resumes Quickshell (`SIGCONT`), powers on displays (`DPMS on`), reloads Hyprland configuration, and releases inhibitor/timer locks.

### 5. Emergency Rescue
```bash
oma-server rescue
```
Unconditionally unfreezes any stopped Quickshell instances, powers on all display outputs, terminates active inhibitor/timer processes, reloads Hyprland configuration, and purges ephemeral lockfiles.

---

## Configuration

Configured via `~/.config/omarchy/plugins/server-mode/config.toml`:

```toml
[profile]
default_mode = "host"
dpms_off_on_enable = true
auto_wake_on_input = true
quickshell_strategy = "sigstop"
default_timeout = "0"              # "0" = manual restore, or e.g. "45m", "2h"

[inhibit]
what = "sleep:idle:handle-lid-switch"
why = "Omarchy Homelab Workload Active"

[whitelist]
# Tier-0 protected services: Guaranteed untouched during mode switches
services = [
  "docker.service",
  "containerd.service",
  "podman.service",
  "tailscaled.service",
  "syncthing.service",
  "caddy.service",
  "nginx.service",
  "sshd.service",
  "pipewire.service",
  "wireplumber.service"
]
```

---

## Dependencies

* `bash` (5.0+)
* `hyprland` / `hyprctl`
* `jq`
* `util-linux` (`flock`)
* `coreutils` (`timeout`, `date`, `tr`)
* `systemd` (`systemd-inhibit`, `systemctl`)

---

## License

MIT (c) RohiRIK
