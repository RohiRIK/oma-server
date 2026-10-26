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
* **Hyprland 0.56+ Lua & Legacy IPC Support**: Automatically detects and applies compositor overrides (`animations`, `decoration.blur`, `decoration.shadow`, `decoration.rounding`) and DPMS control via Hyprland's Lua runtime (`hl.config` / `hl.dsp.dpms`) with seamless fallback to legacy `keyword` / `dpms` IPC.
* **PID-Verified Process Signaling**: Inspects `/proc/<pid>/comm`, `/proc/<pid>/cmdline`, and UID ownership before issuing `SIGSTOP`, `SIGCONT`, or `SIGTERM`, preventing stale PID recycling hazards.
* **Non-Destructive Quickshell Pause**: Pre-notifies the bar widget so `◆` is rendered, then uses user-scoped `SIGSTOP` / `SIGCONT` to pause the shell event loop to 0 CPU ticks without tearing down memory maps, IPC sockets, or window state.
* **Panel Powerdown (DPMS Off)**: Powers down display outputs (`hl.dsp.dpms` / `dpms off`), saving 15-30W and reducing compositor passes to near zero.
* **Session-Detached Lid & Sleep Inhibit**: Spawns a `systemd --user` transient unit (`oma-server-inhibitor.service`) running `systemd-inhibit --no-ask-password` (`sleep:idle:handle-lid-switch`) so closing a laptop lid or logging out of SSH (`SIGHUP`) never halts running containers or background jobs.
* **Dead Man's Switch Timer**: Supports bounded `--timeout <duration>` (`5s` to `7d`, e.g. `oma-server enable --timeout 2h`) via a detached `systemd --user` timer worker (`oma-server-timer.service`) to automatically restore `HOST_LAPTOP` mode when unattended work finishes.
* **Zero Side-Effect Dry-Run**: `oma-server diff` and `oma-server enable --dry-run` evaluate live compositor and service state in a single batched IPC round-trip strictly in memory.

---

## Architecture & State Machine

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          SYSTEM OPERATIONAL STATE                       │
├────────────────────────────────────┬────────────────────────────────────┤
│         HOST_LAPTOP PROFILE        │        HOMELAB_MODE PROFILE        │
│    (Latency & Ergonomics First)    │  (Throughput & Availability First) │
├────────────────────────────────────┼────────────────────────────────────┤
│ - Hyprland shaders & animations ON │ - Compositor throttled (0 FX/blur) │
│ - Omarchy Quickshell active (◇)    │ - Omarchy Quickshell paused (◆)    │
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
4. Installs and registers the Quickshell bar widget in `~/.config/omarchy/plugins/rohirik.oma-server/` (removing any deprecated `BarWidget.qml` from older versions).

To enable and place the widget in the Omarchy status bar:
```bash
omarchy plugin enable rohirik.oma-server --section right
```
*(Once enabled, you can reposition it anytime with `omarchy bar move rohirik.oma-server --section left|center|right`.)*

### Uninstallation

To cleanly restore `HOST_LAPTOP` mode, disable the bar widget, and remove all installed files and hooks:
```bash
./uninstall.sh
```

### Optional: Headless SSH Polkit Rule

When `oma-server enable` is run inside the active desktop or via `systemd --user` on an active graphical seat, `systemd-inhibit` is authorized automatically. On systems where `systemd-logind` requires explicit Polkit authorization for non-seat sessions, install the following optional rule at `/etc/polkit-1/rules.d/49-oma-server-inhibit.rules`:

```javascript
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.inhibit-block-sleep" ||
         action.id == "org.freedesktop.login1.inhibit-block-idle" ||
         action.id == "org.freedesktop.login1.inhibit-handle-lid-switch") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```

---

## Quickshell Telemetry Panel

`oma-server` ships with a native Quickshell bar widget (`Panel.qml`) featuring a zero-emoji, theme-adaptive telemetry interface:

<p align="center">
  <img src="preview.png" alt="Oma Server Panel Component Preview" width="85%">
</p>

* **Bar Indicator**: Vector laptop icon whose screen is illuminated (`lit: true`) in `HOST_LAPTOP` mode, dark/off (`lit: false`) in `HOMELAB_MODE` (reflecting DPMS display powerdown), and pulses smoothly during transitions.
* **Dashboard Popup**:
  * **Hero Header & Status Pill**: Displays mode icon, active profile title, live session elapsed time, and a semantic status pill (`DESKTOP`, `HOMELAB`, `SYNCING`, `DEGRADED`, `ERROR`).
  * **Animated Progress Track**: Displays a smooth progress bar and live elapsed timer during state transitions.
  * **Subsystem Telemetry**: Clean key-value rows reporting Sleep & Lid Inhibit, Display Output, Shell Event Loop, Auto-Revert Timer, and Protected Services.
  * **Auto-Revert Timer Presets**: One-click timeout presets (`Off`, `30m`, `1h`, `2h`, `4h`).
  * **Action Controls**: Primary mode toggle (`Enable Homelab Mode` / `Restore Desktop Mode`), `Plan Diff` terminal launcher, `Refresh`, and `Rescue` emergency recovery.

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
Resumes Quickshell (`SIGCONT`), powers on displays (`DPMS on`), restores captured Hyprland options, and releases inhibitor/timer units.

### 5. Emergency Rescue
```bash
oma-server rescue
```
Unconditionally unfreezes any stopped Quickshell instances, powers on all display outputs, terminates active inhibitor/timer units, reloads Hyprland configuration, and purges ephemeral lockfiles.

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
* `util-linux` (`flock`, `setsid`)
* `coreutils` (`timeout`, `date`, `tr`, `realpath`)
* `systemd` (`systemd-inhibit`, `systemd-run`, `systemctl`)

---

## License

MIT (c) RohiRIK
