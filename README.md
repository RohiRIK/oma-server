<p align="center">
  <img src="assets/banner.png" alt="oma-server banner" width="100%">
</p>

<p align="center">
  <img src="assets/logo.png" alt="oma-server logo" width="110px"><br>
  <strong>Dynamic Performance/Homelab Mode Switcher for Omarchy (Arch + Hyprland + Quickshell)</strong>
</p>

<p align="center">
  <a href="#-the-origin--motivation">Origin & Motivation</a> •
  <a href="#-highlights">Highlights</a> •
  <a href="#️-architecture--philosophy">Architecture</a> •
  <a href="#-installation">Installation</a> •
  <a href="#-usage">Usage</a> •
  <a href="#️-configuration">Configuration</a>
</p>

---

## 💡 The Origin & Motivation

> *"I genuinely love working in Omarchy with the GUI, the fluid Hyprland animations, and the Quickshell bar. But when I'm remote over SSH or letting autonomous AI agents churn through heavy tasks, I don't need any of it."*

Omarchy delivers one of the most aesthetically pleasing, modern Linux desktop experiences available. For interactive daily-driver work, the blur shaders, high-refresh animations, rich status panels, and audio subsystems are a joy to use.

However, a modern workstation often leads a **double life**:
1. **Interactive Station**: When sitting directly in front of the machine, visual polish, low input latency, and desktop comfort are everything.
2. **Compute Node / Agent Runner**: When stepping away, SSHing in from a laptop, or turning the machine over to heavy workloads (autonomous AI agents, container clusters, multi-hour compiles, or media transcoding), the desktop GUI becomes pure deadweight.

Leaving full Hyprland compositing, display panels, and status bar polling active when you are working remotely:
* **Wastes 15–30W of power** keeping physical display panels powered.
* **Consumes GPU memory bandwidth** and compute shaders calculating window beziers and multi-pass blurs that no one is watching.
* **Triggers power management sleep loops** on lid-close or idle timeouts, which can abruptly terminate SSH sessions and agent runs.

**`oma-server` was built to eliminate this compromise.** It gives you the best of both worlds: a full-throttle, headless homelab workhorse whenever you're remote or running agent workflows, with an instantaneous (~1s) return to your beautiful Omarchy desktop the moment you sit back down.

---

## ⚡ Highlights

* **Tier-0 Core Protection**: Hardcoded whitelist guarantees that Docker, Podman, Tailscale, Syncthing, Caddy, SSHD, and PipeWire are never interrupted.
* **Non-Destructive Quickshell Pause**: Uses user-scoped `SIGSTOP` / `SIGCONT` to freeze the shell and event loops to 0 CPU ticks without tearing down memory maps, tray sockets, or window rules.
* **Panel Powerdown (DPMS Off)**: Cuts display power (`hyprctl dispatch dpms off`), saving 15–30W and dropping Hyprland compositing passes to near zero.
* **Lid & Sleep Inhibit**: Engages a non-destructive `systemd-inhibit` lock (`sleep:idle:handle-lid-switch`) so closing your laptop lid never halts running servers or containers.
* **Local Input Wake Guard**: Moving the mouse or typing any key automatically wakes display outputs (`dpms on`).
* **Dead Man's Switch**: Support for `--timeout <duration>` (e.g. `oma-server enable --timeout 2h`) that auto-restores desktop mode when unattended work finishes.
* **Reboot Resilience**: Automatic boot recovery hook cleans up dangling locks and restores full desktop mode after an unexpected reboot.
* **Zero Side-Effects Dry-Run**: `oma-server diff` and `oma-server enable --dry-run` evaluate state strictly in memory.

---

## 🏗️ Architecture & Philosophy

```
+-------------------------------------------------------------------------+
|                              SYSTEM STATE                               |
+------------------------------------+------------------------------------+
|       HOST / LAPTOP MODE           |      PERFORMANCE / HOMELAB MODE    |
|   (Latency & Ergonomics First)     |   (Throughput & Availability First)|
+------------------------------------+------------------------------------+
| • Hyprland shaders & animations ON | • Compositor throttled (VFR, no FX)|
| • Omarchy Quickshell active        | • Omarchy Quickshell suspended     |
| • Standard sleep/lid-close actions | • systemd sleep/lid inhibit active |
| • Audio/portal daemons unthrottled | • Displays DPMS OFF (panel asleep) |
| • Homelab workloads run baseline   | • Homelab workloads get full cache |
+------------------------------------+------------------------------------+
                   │                                    ▲
                   ▼                                    │
           [oma-server enable]                 [oma-server disable]
          (Capture Snapshot)                   (Restore from Snapshot)
```

---

## 📦 Installation

Clone the repository and run the installer:

```bash
git clone https://github.com/RohiRIK/oma-server.git
cd oma-server
./install.sh
```

The installer:
1. Installs the core CLI plugin into `~/.config/omarchy/plugins/server-mode/`.
2. Symlinks `oma-server` into `~/.local/bin/`.
3. Installs the boot recovery hook into `~/.config/omarchy/hooks/post-boot.d/`.
4. Installs the Quickshell bar widget into `~/.config/omarchy/plugins/rohirik.oma-server/`.

To add the widget to your Omarchy status bar:
```bash
omarchy bar move rohirik.oma-server --section right
```

---

## 🖥️ Status Bar Widget & Action Menu

`oma-server` includes a native Quickshell bar widget:

* **Icon State**: Displays `💻` in Laptop Mode, and turns to active `⚡` in Homelab Mode.
* **Left-Click**: One-click toggle between Laptop and Homelab mode.
* **Right-Click**: Opens a quick actions menu:
  * 💻 / ⚡ Toggle Mode
  * 🔍 Preview Transition Diff (opens terminal preview)
  * 🚨 Emergency Reset (rescue)

---

## 💻 CLI Usage

### 1. Check Current Status
```bash
oma-server status
```
Reports whether the machine is in `HOST_LAPTOP` or `HOMELAB_MODE`, active inhibitor PIDs, and runtime state.

### 2. Preview Proposed Transition (Dry-Run)
```bash
# In-memory diff table
oma-server diff

# Full dry-run simulation
oma-server enable --dry-run
```

### 3. Enter Homelab Mode
```bash
# Interactive mode (prompts confirmation)
oma-server enable

# With automatic timeout (Dead Man's Switch)
oma-server enable --timeout 3h
```

### 4. Restore Host / Laptop Desktop
```bash
oma-server disable
```
Restores the desktop session in ~1 second (resumes Quickshell, powers on displays, reloads compositor configs, and releases inhibitor locks).

### 5. Emergency Rescue
```bash
oma-server rescue
```
Emergency fallback to unfreeze Quickshell, turn on all screens, release any lingering power inhibitors, and re-sync Hyprland to disk config.

---

## ⚙️ Configuration

Configured via `~/.config/omarchy/plugins/server-mode/config.toml`:

```toml
[profile]
default_mode = "host"
dpms_off_on_enable = true
auto_wake_on_input = true
quickshell_strategy = "sigstop"
default_timeout = "0"              # "0" = infinite, or e.g. "2h", "45m"

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

## 🛡️ Dependencies

* `bash` (5.0+)
* `hyprland` / `hyprctl`
* `jq`
* `util-linux` (`flock`)
* `systemd` (`systemd-inhibit`)

---

## 📄 License

MIT © RohiRIK
