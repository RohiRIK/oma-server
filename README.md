# oma-server 🚀

> **Dynamic Performance/Homelab Mode Switcher for Omarchy (Arch + Hyprland + Quickshell)**

`oma-server` (Omarchy Server-Mode) allows your Omarchy laptop or workstation to dynamically toggle between a rich consumer desktop and an optimized, high-throughput homelab node without requiring a logout, session restart, or reboot.

When intensive homelab tasks, container workloads, or headless jobs run, `oma-server` safely sheds graphical overhead, pauses the status bar, and inhibits OS sleep—while strictly safeguarding core homelab daemons.

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
1. Installs the plugin into `~/.config/omarchy/plugins/server-mode/`.
2. Symlinks `oma-server` into `~/.local/bin/`.
3. Installs the boot recovery hook into `~/.config/omarchy/hooks/post-boot.d/`.

---

## 💻 Usage

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
