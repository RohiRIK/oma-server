#!/usr/bin/env python3
"""Sandboxed Deep Server Mode tests for oma-server.

Every system binary deep mode touches (systemctl, uwsm, sudo, visudo, pkexec,
loginctl, systemd-run, systemd-inhibit, hyprctl, omarchy-hyprland-window-close-all,
id) is replaced by a PATH shim that records calls and keeps fake unit state in a
throwaway directory. Root files live under OMA_SERVER_TEST_ROOT. Nothing on the
host is stopped, started or installed.
"""
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
OMA_BIN = ROOT / "bin/oma-server"
HELPER = ROOT / "libexec/oma-server-deep-helper"
SUDOERS = ROOT / "templates/sudoers-oma-server-deep"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
REAL_VISUDO = shutil.which("visudo") or ("/usr/sbin/visudo" if os.path.exists("/usr/sbin/visudo") else None)


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class DeepSandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oma-server-deep-test-")
        self.base = pathlib.Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.s = self.base / "fake"          # fake system state
        self.root = self.base / "root"       # OMA_SERVER_TEST_ROOT
        self.home = self.base / "home"
        self.config_home = self.home / ".config"
        self.state_home = self.home / ".local/state"
        self.run_base = self.base / "runtime"
        self.run_dir = self.run_base / "omarchy-server-mode"
        for d in (self.bin, self.s / "user-active", self.s / "sys-active", self.root, self.home, self.state_home):
            d.mkdir(parents=True, exist_ok=True)
        self.run_base.mkdir(mode=0o700)
        self.log = self.s / "calls.log"
        self.log.touch()
        self.cfg_dir = self.config_home / "omarchy/plugins/server-mode"
        self.cfg_dir.mkdir(parents=True)
        self.cfg = self.cfg_dir / "config.toml"
        self.write_config(allowed=True)
        self.deep_dir = self.state_home / "oma-server"
        self.helper_path = self.root / "usr/local/lib/oma-server/deep-helper"
        self.sudoers_path = self.root / "etc/sudoers.d/oma-server-deep"
        (self.root / "etc/sudoers.d").mkdir(parents=True)
        (self.root / "etc/sddm.conf.d").mkdir(parents=True)
        (self.root / "etc/sddm.conf.d/autologin.conf").write_text("[Autologin]\nUser=me\n")
        # Desktop up, greeter running, sshd running, linger off, autologin works
        self.set_active("user", "wayland-wm@hyprland.desktop.service")
        self.set_active("user", "graphical-session.target")
        self.set_active("sys", "display-manager.service")
        self.set_active("sys", "sshd.service")
        (self.s / "linger").write_text("no")
        (self.s / "autologin_works").touch()
        (self.s / "clients.json").write_text("[]")
        self._write_stubs()

    def tearDown(self):
        self.tmp.cleanup()

    # ---- fixtures ----------------------------------------------------------
    def write_config(self, allowed=True, extra=""):
        src = (ROOT / "config/config.toml").read_text(encoding="utf-8")
        src = src.replace("allowed = false", f"allowed = {'true' if allowed else 'false'}")
        src = src.replace("exit_wait_seconds = 45", "exit_wait_seconds = 1")
        self.cfg.write_text(src + extra, encoding="utf-8")

    def install_helper(self, grant=True):
        self.helper_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(HELPER, self.helper_path)
        shutil.copy(SUDOERS, self.sudoers_path)
        if grant:
            (self.s / "grant").touch()

    def set_active(self, scope, unit, on=True):
        p = self.s / f"{scope}-active" / unit
        if on:
            p.touch()
        else:
            p.unlink(missing_ok=True)

    def is_active(self, scope, unit):
        return (self.s / f"{scope}-active" / unit).exists()

    def set_clients(self, clients):
        (self.s / "clients.json").write_text(json.dumps(clients))

    def calls(self):
        return self.log.read_text(encoding="utf-8").splitlines()

    def deep_state(self):
        p = self.deep_dir / "deep.json"
        return json.loads(p.read_text()) if p.exists() else None

    def last_deep(self):
        p = self.deep_dir / "last-deep.json"
        return json.loads(p.read_text()) if p.exists() else None

    def write_deep_state(self, **overrides):
        self.deep_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        boot = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        st = {"state": "DEEP_SERVER", "entered_at": 1000, "boot_id": boot, "timeout_epoch": None,
              "timeout_seconds": 0, "timeout_label": "", "closed_clients": [], "linger_was": "no",
              "dm_stopped": True, "ram_before_mb": 1000, "ram_after_mb": 2000}
        st.update(overrides)
        (self.deep_dir / "deep.json").write_text(json.dumps(st))

    def enter_desktop_down(self):
        """Fake the post-enter world: no Hyprland, no greeter, linger on, inhibitor held."""
        self.set_active("user", "wayland-wm@hyprland.desktop.service", False)
        self.set_active("user", "graphical-session.target", False)
        self.set_active("sys", "display-manager.service", False)
        (self.s / "linger").write_text("yes")
        (self.s / "inhibit").touch()

    # ---- stubs -------------------------------------------------------------
    def _write_stubs(self):
        S, L = self.s, self.log
        helper = self.helper_path
        write_executable(self.bin / "systemctl", f"""#!/usr/bin/env bash
S="{S}"; echo "systemctl $*" >> "{L}"
scope=sys; [[ "$1" == "--user" ]] && {{ scope=user; shift; }}
cmd="$1"; shift || true
args=(); for a in "$@"; do [[ "$a" == --* ]] || args+=("$a"); done
case "$cmd" in
  is-active)
    q=0; for a in "$@"; do [[ "$a" == "--quiet" ]] && q=1; done
    if [[ -e "$S/$scope-active/${{args[0]}}" ]]; then (( q )) || echo active; exit 0; fi
    if [[ -e "$S/$scope-activating/${{args[0]}}" ]]; then (( q )) || echo activating; exit 3; fi
    (( q )) || echo inactive; exit 3 ;;
  list-jobs) [[ -e "$S/user-jobs" ]] && cat "$S/user-jobs"; exit 0 ;;
  is-failed) [[ -e "$S/$scope-failed/${{args[0]}}" ]] && exit 0 || exit 1 ;;
  stop) for u in "${{args[@]}}"; do rm -f "$S/$scope-active/$u"; done; exit 0 ;;
  start) for u in "${{args[@]}}"; do touch "$S/$scope-active/$u"; done; exit 0 ;;
  *) exit 0 ;;
esac
""")
        write_executable(self.bin / "uwsm", f"""#!/usr/bin/env bash
S="{S}"; echo "uwsm $*" >> "{L}"
if [[ "$1" == "stop" ]]; then
  [[ "${{OMA_TEST_UWSM_FAIL:-0}}" == "1" ]] && exit 1
  if [[ "${{OMA_TEST_UWSM_FAIL_ONCE:-0}}" == "1" && ! -e "$S/uwsm-failed-once" ]]; then
    touch "$S/uwsm-failed-once"
    echo "Failed to stop wayland-wm@hyprland.desktop.service: Transaction for wayland-wm@hyprland.desktop.service/stop is destructive (org.freedesktop.systemd1.TransactionIsDestructive)" >&2
    exit 1
  fi
  rm -f "$S/user-active/wayland-wm@hyprland.desktop.service" "$S/user-active/graphical-session.target"
  echo "[]" > "$S/clients.json"
fi
exit 0
""")
        write_executable(self.bin / "sudo", f"""#!/usr/bin/env bash
S="{S}"; HELPER="{helper}"
if [[ "$1" == "-V" ]]; then echo "Sudo version ${{OMA_TEST_SUDO_VERSION:-1.9.16}}"; exit 0; fi
nflag=""
if [[ "$1" == "-n" ]]; then nflag="-n "; shift; fi
if [[ "$1" == "-l" && "$2" == "-l" ]]; then
  echo "sudo ${{nflag}}-l -l ${{*:3}}" >> "{L}"
  [[ -e "$S/grant" && -f "$HELPER" ]] && {{ echo "Options: !authenticate"; exit 0; }}
  exit 1
fi
if [[ "$1" == "-l" ]]; then
  echo "sudo ${{nflag}}-l" >> "{L}"
  [[ -e "$S/list-needs-pw" ]] && {{ echo "sudo: a password is required" >&2; exit 1; }}
  echo "User tester may run the following commands:"
  echo "    (ALL) /usr/bin/true"
  [[ -e "{self.sudoers_path}" ]] && echo "    (root) NOPASSWD: $HELPER check, $HELPER dm-stop"
  exit 0
fi
echo "sudo ${{nflag}}$*" >> "{L}"
if [[ "$1" == "$HELPER" ]]; then
  verb="$2"
  [[ -n "$nflag" && ! -e "$S/grant" ]] && {{ echo "sudo: a password is required" >&2; exit 1; }}
  case "$verb" in
    dm-stop) [[ "${{OMA_TEST_DMSTOP_FAIL:-0}}" == "1" ]] && exit 1; rm -f "$S/sys-active/display-manager.service" ;;
    dm-start|dm-restart)
      [[ "${{OMA_TEST_DMSTART_FAIL:-0}}" == "1" ]] && exit 1
      touch "$S/sys-active/display-manager.service"
      if [[ -e "$S/autologin_works" ]]; then
        touch "$S/user-active/wayland-wm@hyprland.desktop.service" "$S/user-active/graphical-session.target"
      fi ;;
    inhibit-start) [[ "${{OMA_TEST_INHIBIT_FAIL:-0}}" == "1" ]] && exit 1; touch "$S/inhibit" ;;
    inhibit-stop) rm -f "$S/inhibit" ;;
    revert-arm) touch "$S/revert" ;;
    revert-disarm) rm -f "$S/revert" ;;
    check) echo ok ;;
    *) exit 2 ;;
  esac
  exit 0
fi
case "$1" in
  chown) exit 0 ;;   # cannot chown to root in the sandbox
  install)
    if [[ "${{OMA_TEST_STAGE_TAMPER:-0}}" == "1" && "${{@: -1}}" == *.oma-server-deep.tmp ]]; then
      "$@"; rc=$?; chmod u+w "${{@: -1}}"; echo "ALL ALL=(ALL) NOPASSWD: ALL" >> "${{@: -1}}"; exit $rc
    fi
    exec "$@" ;;
  visudo)
    shift
    if [[ "${{OMA_TEST_VISUDO_FAIL:-0}}" == "1" ]]; then echo "parse error" >&2; exit 1; fi
    exit 0 ;;
  *) exec "$@" ;;
esac
""")
        write_executable(self.bin / "pkexec", f"""#!/usr/bin/env bash
echo "pkexec $*" >> "{L}"; exit 0
""")
        write_executable(self.bin / "loginctl", f"""#!/usr/bin/env bash
S="{S}"; echo "loginctl $*" >> "{L}"
case "$1" in
  show-user) cat "$S/linger" ;;
  enable-linger) echo yes > "$S/linger" ;;
  disable-linger) echo no > "$S/linger" ;;
esac
exit 0
""")
        write_executable(self.bin / "systemd-run", f"""#!/usr/bin/env bash
S="{S}"; echo "systemd-run $*" >> "{L}"
timer=0
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --on-active=*) timer=1 ;;
    --setenv=*) kv="${{1#--setenv=}}"; export "${{kv%%=*}}=${{kv#*=}}" ;;
  esac
  shift
done
[[ "${{OMA_TEST_SYSTEMD_RUN_FAIL:-0}}" == "1" ]] && exit 1
if (( timer )); then touch "$S/user-timer"; exit 0; fi
# Run the detached worker synchronously so the test can observe the outcome.
"$@" </dev/null >/dev/null 2>&1 || true
exit 0
""")
        write_executable(self.bin / "systemd-inhibit", f"""#!/usr/bin/env bash
S="{S}"
if [[ "$1" == "--list" ]]; then
  [[ -e "$S/inhibit" ]] && echo "oma-server 0 root 1 systemd-inhibit sleep:idle:handle-lid-switch block"
  exit 0
fi
exit 0
""")
        write_executable(self.bin / "hyprctl", f"""#!/usr/bin/env bash
S="{S}"
[[ "${{OMA_TEST_HYPR_FAIL:-0}}" == "1" ]] && exit 1
[[ -e "$S/hypr-broken" ]] && exit 1
if [[ -e "$S/hypr-fail-once" ]]; then rm -f "$S/hypr-fail-once"; echo "HYPRLAND_INSTANCE_SIGNATURE invalid" ; exit 1; fi
if [[ "$1" == "clients" ]]; then cat "$S/clients.json"; exit 0; fi
if [[ "$1" == "-j" && "$2" == "monitors" ]]; then echo '[{{"name":"eDP-1","dpmsStatus":true}}]'; exit 0; fi
echo ok
""")
        write_executable(self.bin / "omarchy-hyprland-window-close-all", f"""#!/usr/bin/env bash
echo "window-close-all" >> "{L}"
[[ "${{OMA_TEST_CLOSE_BREAKS_IPC:-0}}" == "1" ]] && touch "{S}/hypr-broken"
[[ "${{OMA_TEST_WINDOWS_STUCK:-0}}" == "1" ]] || echo "[]" > "{S}/clients.json"
exit 0
""")
        write_executable(self.bin / "id", """#!/usr/bin/env bash
if [[ "$1" == "-nG" ]]; then echo "user wheel"; exit 0; fi
if [[ "$1" == "-u" && "${OMA_TEST_FAKE_ROOT:-0}" == "1" ]]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
""")
        for name in ("pgrep",):
            write_executable(self.bin / name, """#!/usr/bin/env bash
if [[ "$*" == *"quickshell"* || "$*" == *"omarchy-shell"* ]]; then exit 1; fi
exec /usr/bin/pgrep "$@"
""")
        write_executable(self.bin / "omarchy-shell", "#!/usr/bin/env bash\nexit 0\n")

    # ---- runners -----------------------------------------------------------
    def env(self, extra=None):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "USER": "tester",
            "XDG_CONFIG_HOME": str(self.config_home),
            "XDG_STATE_HOME": str(self.state_home),
            "OMA_SERVER_RUNTIME_BASE": str(self.run_base),
            "OMA_SERVER_RUN_DIR": str(self.run_dir),
            "OMA_SERVER_TEST_ROOT": str(self.root),
            "OMA_SERVER_TEST_MODE": "1",
            "OMA_DEEP_POLL_INTERVAL": "0.05",
            "OMA_DEEP_FOLLOW_SECONDS": "5",
            "TERM": "dumb",
        }
        if extra:
            env.update(extra)
        return env

    def cli(self, *args, extra_env=None, stdin_data=None):
        res = subprocess.run([str(OMA_BIN), *args], input=stdin_data, capture_output=True, text=True,
                             env=self.env(extra_env), timeout=60)
        res.plain = ANSI_RE.sub("", res.stdout + res.stderr)
        return res

    def cli_tty(self, *args, answers="", extra_env=None):
        """Run the CLI on a pseudo-TTY (util-linux `script`), feeding `answers`."""
        if not shutil.which("script"):
            self.skipTest("util-linux 'script' not available")
        cmd = " ".join([str(OMA_BIN), *args]) + "; echo __RC=$?"
        res = subprocess.run(["script", "-qec", cmd, "/dev/null"], input=answers, capture_output=True,
                             text=True, env=self.env(extra_env), timeout=60)
        out = ANSI_RE.sub("", res.stdout + res.stderr)
        m = re.search(r"__RC=(\d+)", out)
        res.rc = int(m.group(1)) if m else -1
        res.plain = out
        return res


class HelperAndSudoersTests(unittest.TestCase):
    def run_helper(self, *args):
        return subprocess.run(["bash", str(HELPER), *args], capture_output=True, text=True, timeout=10)

    def test_helper_rejects_unknown_verbs_and_extra_args(self):
        for args in ([], ["bogus"], ["dm-stop", "x"], ["check", "--force"], ["exit", "/etc/passwd"],
                     ["systemctl"], ["dm-stop;id"], ["revert-arm"], ["revert-arm", "1", "2"]):
            res = self.run_helper(*args)
            self.assertEqual(res.returncode, 2, f"{args} should be rejected: {res.stderr}")

    def test_helper_revalidates_seconds(self):
        for bad in ("0", "4", "604921", "9999999", "12a", "-5", "1e3", " 60", "060", "$(id)"):
            res = self.run_helper("revert-arm", bad)
            self.assertEqual(res.returncode, 2, f"revert-arm {bad!r} should be rejected")

    def test_valid_verbs_require_root(self):
        if os.geteuid() == 0:
            self.skipTest("running as root")
        for args in (["check"], ["dm-stop"], ["revert-arm", "60"]):
            res = self.run_helper(*args)
            self.assertEqual(res.returncode, 1)
            self.assertIn("must run as root", res.stderr)

    def test_helper_static_safety(self):
        src = HELPER.read_text(encoding="utf-8")
        self.assertIn("PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin", src)
        self.assertNotRegex(src, r"\beval\b")
        self.assertNotIn("bash -c", src)
        self.assertNotIn('"$@"', src.split("# ---- 2.")[1], "helper must not forward arguments")

    def test_sudoers_template_is_exact(self):
        text = SUDOERS.read_text(encoding="utf-8")
        rule = " ".join(l.rstrip("\\").strip() for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#"))
        self.assertTrue(rule.startswith("%wheel ALL=(root) NOPASSWD: "))
        cmds = [c.strip() for c in re.split(r"(?<!\\),", rule.split("NOPASSWD:", 1)[1])]
        verbs = set()
        for c in cmds:
            self.assertTrue(c.startswith("/usr/local/lib/oma-server/deep-helper "), c)
            verbs.add(c.split(" ", 1)[1])
        self.assertEqual(verbs, {"check", "dm-stop", "dm-start", "dm-restart", "inhibit-start", "inhibit-stop",
                                 "revert-disarm", "exit", r"^revert-arm [1-9][0-9]{0\,5}$"})
        self.assertNotIn("*", rule)
        self.assertNotIn("ALL, ", rule)

    @unittest.skipUnless(REAL_VISUDO, "visudo not installed")
    def test_sudoers_template_passes_visudo(self):
        res = subprocess.run([REAL_VISUDO, "-cf", str(SUDOERS)], capture_output=True, text=True)
        if res.returncode != 0 and "regular expressions are not supported" in (res.stdout + res.stderr):
            # Some distro builds (e.g. Ubuntu's sudo) lack sudoers regex support. Omarchy/Arch
            # has it; on such hosts deep-setup's visudo -cf fails closed and installs nothing.
            # Still prove the rest of the file parses by validating it without the regex line.
            stripped = re.sub(r",\s*\\\n\s*/usr/local/lib/oma-server/deep-helper \^revert-arm[^\n]*", "",
                              SUDOERS.read_text(encoding="utf-8"))
            self.assertNotIn("^revert-arm", stripped)
            with tempfile.NamedTemporaryFile("w", suffix=".sudoers", delete=False) as fh:
                fh.write(stripped)
            try:
                res2 = subprocess.run([REAL_VISUDO, "-cf", fh.name], capture_output=True, text=True)
                self.assertEqual(res2.returncode, 0, res2.stdout + res2.stderr)
            finally:
                os.unlink(fh.name)
            self.skipTest("this visudo build has no regex support; regex line checked on sudo 1.9.16 separately")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


class PrivilegeLadderTests(DeepSandbox):
    def ladder(self, extra_env=None, snapshot=False, deep_state=False):
        snap = self.run_dir / "active-snapshot.json"
        if snapshot:
            self.run_dir.mkdir(exist_ok=True)
            snap.write_text("{}")
        if deep_state:
            self.write_deep_state()
        script = (f"source {ROOT}/lib/ui.sh; source {ROOT}/lib/config.sh; source {ROOT}/lib/deep.sh; "
                  f"SNAPSHOT_FILE={snap}; deep_helper_root dm-start")
        env = self.env(extra_env)
        for k in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "WAYLAND_DISPLAY"):
            if not extra_env or k not in extra_env:
                env.pop(k, None)
        return subprocess.run(["bash", "-c", script], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, env=env, timeout=20)

    def test_grant_uses_sudo_n(self):
        self.install_helper(grant=True)
        res = self.ladder({"WAYLAND_DISPLAY": "wayland-1"})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn(f"sudo -n {self.helper_path} dm-start", self.calls())
        self.assertFalse(any(c.startswith("pkexec") for c in self.calls()))

    def test_gui_laptop_without_grant_uses_pkexec(self):
        self.install_helper(grant=False)
        res = self.ladder({"WAYLAND_DISPLAY": "wayland-1"})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn(f"pkexec {self.helper_path} dm-start", self.calls())

    def test_never_pkexec_over_ssh(self):
        self.install_helper(grant=False)
        for var in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"):
            self.log.write_text("")
            res = self.ladder({"WAYLAND_DISPLAY": "wayland-1", var: "10.0.0.2 5000 10.0.0.1 22"})
            self.assertNotEqual(res.returncode, 0)
            self.assertFalse(any(c.startswith("pkexec") for c in self.calls()), var)
            self.assertIn("ssh -t", ANSI_RE.sub("", res.stderr))

    def test_never_pkexec_in_homelab_or_deep_or_headless(self):
        self.install_helper(grant=False)
        for kwargs, env in (({"snapshot": True}, {"WAYLAND_DISPLAY": "wayland-1"}),
                            ({"deep_state": True}, {"WAYLAND_DISPLAY": "wayland-1"}),
                            ({}, {})):
            self.log.write_text("")
            res = self.ladder(env, **kwargs)
            self.assertNotEqual(res.returncode, 0, kwargs)
            self.assertFalse(any(c.startswith("pkexec") for c in self.calls()), kwargs)

    def test_tty_uses_plain_sudo(self):
        if not shutil.which("script"):
            self.skipTest("no script")
        self.install_helper(grant=False)
        script = (f"source {ROOT}/lib/ui.sh; source {ROOT}/lib/config.sh; source {ROOT}/lib/deep.sh; "
                  f"deep_helper_root dm-start")
        subprocess.run(["script", "-qec", f"bash -c '{script}'", "/dev/null"], input="", capture_output=True,
                       text=True, env=self.env(), timeout=20)
        self.assertIn(f"sudo {self.helper_path} dm-start", self.calls())


class DeepEnterTests(DeepSandbox):
    def helper_calls(self):
        return [c.split("deep-helper ", 1)[1] for c in self.calls()
                if "deep-helper " in c and c.startswith("sudo") and "-l -l" not in c]

    def test_refuses_when_not_set_up(self):
        self.install_helper()
        self.write_config(allowed=False)
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("deep-setup", res.plain)
        self.assertIsNone(self.deep_state())

    def test_refuses_without_grant(self):
        self.install_helper(grant=False)
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("deep-setup", res.plain)
        self.assertEqual(self.helper_calls(), [])

    def test_refuses_without_sshd_when_required(self):
        self.install_helper()
        self.set_active("sys", "sshd.service", False)
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("sshd.service is not active", res.plain)

    def test_refuses_from_homelab(self):
        self.install_helper()
        self.run_dir.mkdir()
        (self.run_dir / "active-snapshot.json").write_text("{}")
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("HOMELAB_MODE is active", res.plain)

    def test_yes_flag_is_rejected(self):
        self.install_helper()
        res = self.cli("enable", "--deep", "-y")
        self.assertEqual(res.returncode, 2)
        self.assertIsNone(self.deep_state())

    def test_refuses_and_lists_open_windows(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "notes.md", "pid": 4242}])
        res = self.cli("enable", "--deep")
        self.assertEqual(res.returncode, 3, res.plain)
        self.assertIn("foot: notes.md (pid 4242)", res.plain)
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.helper_calls(), [])
        self.assertNotIn("window-close-all", self.calls())

    def test_close_apps_without_tty_refuses(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "x", "pid": 1}])
        res = self.cli("enable", "--deep", "--close-apps", stdin_data="yes\n")
        self.assertEqual(res.returncode, 3)
        self.assertIn("not a TTY", res.plain)
        self.assertIsNone(self.deep_state())

    def test_close_apps_requires_literal_yes(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "x", "pid": 1}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="y\n")
        self.assertEqual(res.rc, 3, res.plain)
        self.assertNotIn("window-close-all", self.calls())
        self.assertTrue(self.is_active("user", "wayland-wm@hyprland.desktop.service"))

    def test_close_apps_with_yes_enters(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "x", "pid": 1}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="yes\n\n")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertIn("window-close-all", self.calls())
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")
        self.assertEqual(self.deep_state()["closed_clients"][0]["class"], "foot")

    def test_enter_sequence_without_timeout(self):
        self.install_helper()
        res = self.cli("enable", "--deep")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("No --timeout", res.plain)
        st = self.deep_state()
        self.assertEqual(st["state"], "DEEP_SERVER")
        self.assertEqual(st["linger_was"], "no")
        self.assertIsNone(st["timeout_epoch"])
        calls = self.calls()
        def idx(pred):
            return next(i for i, c in enumerate(calls) if pred(c))
        i_linger = idx(lambda c: c == "loginctl enable-linger tester")
        i_inhibit = idx(lambda c: c.endswith("deep-helper inhibit-start"))
        i_uwsm = idx(lambda c: c == "uwsm stop")
        i_dm = idx(lambda c: c.endswith("deep-helper dm-stop"))
        self.assertLess(i_linger, i_inhibit)
        self.assertLess(i_inhibit, i_uwsm)
        self.assertLess(i_uwsm, i_dm)
        # No timers at all without --timeout
        self.assertFalse(any("--on-active" in c for c in calls))
        self.assertNotIn("revert-arm", " ".join(self.helper_calls()))
        self.assertFalse((self.s / "user-timer").exists())
        self.assertFalse(self.is_active("sys", "display-manager.service"))
        self.assertTrue((self.s / "inhibit").exists())
        # Deep mode never reads [profile] default_timeout
        self.assertTrue(any("sudo -n" in c and "dm-stop" in c for c in calls))

    def test_default_timeout_is_ignored_in_deep_mode(self):
        self.install_helper()
        self.cfg.write_text(self.cfg.read_text().replace('default_timeout = "0"', 'default_timeout = "2h"'))
        res = self.cli("enable", "--deep")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertFalse(any("--on-active" in c for c in self.calls()))

    def test_enter_with_timeout_arms_both_timers(self):
        self.install_helper()
        res = self.cli("enable", "--deep", "--timeout", "2m")
        self.assertEqual(res.returncode, 0, res.plain)
        calls = self.calls()
        self.assertTrue(any("--unit=oma-server-timer" in c and "--on-active=120s" in c and "disable --auto-timeout" in c
                            for c in calls), calls)
        self.assertIn("revert-arm 240", self.helper_calls())
        self.assertIsNotNone(self.deep_state()["timeout_epoch"])

    def test_uwsm_failure_rolls_back(self):
        self.install_helper()
        res = self.cli("enable", "--deep", "--timeout", "2m", extra_env={"OMA_TEST_UWSM_FAIL": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        self.assertIn("rolled back", res.plain)
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.last_deep()["result"], "rolled_back")
        hc = self.helper_calls()
        self.assertIn("inhibit-stop", hc)
        self.assertIn("revert-disarm", hc)
        self.assertNotIn("dm-stop", hc)
        self.assertEqual((self.s / "linger").read_text().strip(), "no")
        self.assertFalse((self.s / "inhibit").exists())
        self.assertTrue(self.is_active("user", "wayland-wm@hyprland.desktop.service"))

    def test_stuck_windows_roll_back(self):
        self.install_helper()
        self.set_clients([{"class": "gimp", "title": "Save changes?", "pid": 7}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="yes\n\n",
                           extra_env={"OMA_TEST_WINDOWS_STUCK": "1"})
        self.assertEqual(res.rc, 1, res.plain)
        self.assertIsNone(self.deep_state())
        self.assertIn("did not close", self.last_deep()["reason"])
        self.assertNotIn("uwsm stop", self.calls())

    def test_inhibitor_failure_rolls_back_before_session(self):
        self.install_helper()
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_INHIBIT_FAIL": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertNotIn("uwsm stop", self.calls())
        self.assertEqual((self.s / "linger").read_text().strip(), "no")

    def test_dm_stop_failure_runs_exit_sequence(self):
        self.install_helper()
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_DMSTOP_FAIL": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        hc = self.helper_calls()
        self.assertIn("dm-stop", hc)
        after = hc[hc.index("dm-stop") + 1:]
        # The greeter is still running, so the exit restarts it (a plain start would be a no-op).
        self.assertIn("dm-restart", after)
        self.assertIsNone(self.deep_state())
        self.assertTrue(self.is_active("user", "wayland-wm@hyprland.desktop.service"))
        self.assertFalse((self.s / "inhibit").exists())

    def test_systemd_run_failure_changes_nothing(self):
        self.install_helper()
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_SYSTEMD_RUN_FAIL": "1"})
        self.assertEqual(res.returncode, 1)
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.helper_calls(), [])

    def test_status_json_reports_deep(self):
        self.install_helper()
        self.cli("enable", "--deep")
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual(st["mode"], "DEEP_SERVER")
        self.assertTrue(st["is_deep"])
        self.assertTrue(st["deep_allowed"])


class DeepExitTests(DeepSandbox):
    def helper_calls(self):
        return [c.split("deep-helper ", 1)[1] for c in self.calls()
                if "deep-helper " in c and c.startswith("sudo") and "-l -l" not in c]

    def test_disable_restores_desktop(self):
        self.install_helper()
        self.write_deep_state(timeout_seconds=120)
        self.enter_desktop_down()
        self.set_active("user", "graphical-session.target")  # leftover (omarchy#9589)
        res = self.cli("disable")
        self.assertEqual(res.returncode, 0, res.plain)
        calls = self.calls()
        i_gs = calls.index("systemctl --user stop graphical-session.target wayland-session@hyprland.desktop.target")
        i_dm = next(i for i, c in enumerate(calls) if c.endswith("deep-helper dm-start"))
        i_inh = next(i for i, c in enumerate(calls) if c.endswith("deep-helper inhibit-stop"))
        self.assertLess(i_gs, i_dm)
        self.assertLess(i_dm, i_inh)
        self.assertIn("revert-disarm", self.helper_calls())
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.last_deep()["result"], "exited")
        self.assertEqual(self.last_deep()["freed_mb"], 1000)
        self.assertEqual((self.s / "linger").read_text().strip(), "no")
        self.assertTrue(self.is_active("sys", "display-manager.service"))

    def test_exit_retries_once_then_degraded_and_keeps_inhibitor(self):
        self.install_helper()
        self.write_deep_state()
        self.enter_desktop_down()
        (self.s / "autologin_works").unlink()
        res = self.cli("disable")
        self.assertEqual(res.returncode, 1, res.plain)
        self.assertIn("Desktop did not come back", res.plain)
        hc = self.helper_calls()
        self.assertEqual(hc.count("dm-restart"), 1, hc)
        self.assertNotIn("inhibit-stop", hc)
        self.assertTrue((self.s / "inhibit").exists())
        self.assertEqual(self.deep_state()["state"], "DEEP_DEGRADED")
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual(st["health"], "DEGRADED")
        # retry once autologin works again
        (self.s / "autologin_works").touch()
        res2 = self.cli("disable")
        self.assertEqual(res2.returncode, 0, res2.plain)
        self.assertIsNone(self.deep_state())

    def test_password_login_greeter_counts_as_success(self):
        self.install_helper()
        self.write_deep_state()
        self.enter_desktop_down()
        (self.s / "autologin_works").unlink()
        (self.root / "etc/sddm.conf.d/autologin.conf").unlink()
        res = self.cli("disable")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("log in at the screen", res.plain)
        self.assertEqual(self.last_deep()["result"], "greeter")

    def test_auto_timeout_never_stops_its_own_service(self):
        self.install_helper()
        self.write_deep_state(timeout_seconds=120)
        self.enter_desktop_down()
        res = self.cli("disable", "--auto-timeout")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("systemctl --user stop oma-server-timer.timer", self.calls())
        self.assertNotIn("systemctl --user stop oma-server-timer.service", self.calls())

    def test_boot_id_mismatch_clears_state(self):
        self.install_helper()
        self.write_deep_state(boot_id="00000000-dead-beef-0000-000000000000")
        res = self.cli("status", "--json")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(json.loads(res.stdout)["mode"], "HOST_LAPTOP")
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.last_deep()["result"], "rebooted")
        self.assertIn("inhibit-stop", self.helper_calls())

    def test_post_boot_finishes_root_backup_exit(self):
        self.install_helper()
        self.write_deep_state()   # desktop is up again (root timer started the DM)
        res = self.cli("__deep-post-boot")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIsNone(self.deep_state())


class HookTests(DeepSandbox):
    def run_hook(self):
        write_executable(self.bin / "oma-server", f"""#!/usr/bin/env bash
echo "oma-server $*" >> "{self.log}"
""")
        return subprocess.run(["bash", str(ROOT / "hooks/post-boot.d/99-server-profile-check.sh")],
                              capture_output=True, text=True, env=self.env(), timeout=20)

    def test_hook_skips_during_deep_exiting(self):
        self.write_deep_state(state="DEEP_EXITING")
        res = self.run_hook()
        self.assertEqual(res.returncode, 0)
        self.assertNotIn("oma-server __deep-post-boot", self.calls())
        self.assertIsNotNone(self.deep_state(), "hook must never purge deep.json during an exit")

    def test_hook_skips_while_lock_held(self):
        self.write_deep_state(state="DEEP_SERVER")
        lock = self.deep_dir / "deep.lock"
        holder = subprocess.Popen(["flock", str(lock), "sleep", "5"])
        try:
            import time
            time.sleep(0.3)
            self.run_hook()
            self.assertNotIn("oma-server __deep-post-boot", self.calls())
        finally:
            holder.kill()

    def test_hook_hands_deep_server_to_cli(self):
        self.write_deep_state(state="DEEP_SERVER")
        self.run_hook()
        self.assertIn("oma-server __deep-post-boot", self.calls())


class DeepSetupTests(DeepSandbox):
    def test_setup_requires_tty(self):
        res = self.cli("deep-setup")
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(self.helper_path.exists())

    def test_setup_installs_after_validation(self):
        self.write_config(allowed=False)
        res = self.cli_tty("deep-setup", answers="y\n")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertTrue(self.helper_path.is_file())
        self.assertEqual(self.helper_path.read_bytes(), HELPER.read_bytes())
        self.assertEqual(stat.S_IMODE(self.helper_path.stat().st_mode), 0o755)
        self.assertTrue(self.sudoers_path.is_file())
        self.assertEqual(stat.S_IMODE(self.sudoers_path.stat().st_mode), 0o440)
        self.assertFalse((self.sudoers_path.parent / ".oma-server-deep.tmp").exists())
        calls = self.calls()
        i_val = next(i for i, c in enumerate(calls) if c.startswith("sudo visudo -cf"))
        i_helper = next(i for i, c in enumerate(calls) if c.startswith("sudo install -m 0755"))
        i_activate = next(i for i, c in enumerate(calls) if c.startswith("sudo mv -f") and c.endswith("oma-server-deep"))
        self.assertLess(i_val, i_helper)
        self.assertLess(i_helper, i_activate)
        self.assertIn("allowed = true", self.cfg.read_text())

    def test_visudo_failure_aborts_without_installing(self):
        self.write_config(allowed=False)
        res = self.cli_tty("deep-setup", answers="y\n", extra_env={"OMA_TEST_VISUDO_FAIL": "1"})
        self.assertNotEqual(res.rc, 0, res.plain)
        self.assertIn("validation", res.plain)
        self.assertFalse(self.helper_path.exists())
        self.assertFalse(self.sudoers_path.exists())
        self.assertEqual(list(self.sudoers_path.parent.iterdir()), [])
        self.assertIn("allowed = false", self.cfg.read_text())

    def test_setup_declined_installs_nothing(self):
        self.write_config(allowed=False)
        res = self.cli_tty("deep-setup", answers="\n")
        self.assertNotEqual(res.rc, 0)
        self.assertFalse(self.helper_path.exists())
        self.assertFalse(any(c.startswith("sudo install") for c in self.calls()))

    def test_old_sudo_refused(self):
        res = self.cli_tty("deep-setup", answers="y\n", extra_env={"OMA_TEST_SUDO_VERSION": "1.9.9"})
        self.assertNotEqual(res.rc, 0)
        self.assertFalse(self.helper_path.exists())

    def test_remove_cleans_up(self):
        self.install_helper()
        res = self.cli_tty("deep-setup", "--remove")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertFalse(self.helper_path.exists())
        self.assertFalse(self.sudoers_path.exists())
        self.assertFalse(self.helper_path.parent.exists())
        self.assertIn("allowed = false", self.cfg.read_text())
        calls = self.calls()
        i_sud = next(i for i, c in enumerate(calls) if c.startswith("sudo rm -f") and "sudoers" in c)
        i_hel = next(i for i, c in enumerate(calls) if c.startswith("sudo rm -f") and "deep-helper" in c)
        self.assertLess(i_sud, i_hel, "grant must be revoked before the helper is removed")

    def test_remove_refused_while_deep_active(self):
        self.install_helper()
        self.write_deep_state()
        res = self.cli_tty("deep-setup", "--remove")
        self.assertNotEqual(res.rc, 0)
        self.assertTrue(self.sudoers_path.exists())


class InstallUninstallDeepTests(DeepSandbox):
    def run_script(self, name, *args):
        env = self.env()
        return subprocess.run(["bash", str(ROOT / name), *args], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, env=env, timeout=60)

    def test_install_never_installs_root_files_or_enables_deep(self):
        self.cfg.unlink()
        res = self.run_script("install.sh")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertFalse(self.helper_path.exists())
        self.assertFalse(self.sudoers_path.exists())
        self.assertFalse(any(c.startswith("sudo") for c in self.calls()))
        self.assertIn("allowed = false", self.cfg.read_text())
        self.assertTrue((self.cfg_dir / "libexec/oma-server-deep-helper").is_file())
        launcher = self.cfg_dir / "libexec/oma-server-deep-shell"
        self.assertTrue(launcher.is_file() and os.access(launcher, os.X_OK))
        self.assertFalse((self.home / ".bash_profile").exists(), "install must not touch login profiles")

    def test_uninstall_refuses_while_deep_active(self):
        self.run_script("install.sh")
        self.write_deep_state()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 1)
        self.assertTrue((self.cfg_dir / "bin/oma-server").exists())

    def test_uninstall_without_tty_refuses_when_helper_installed(self):
        self.run_script("install.sh")
        self.install_helper()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 1)
        self.assertIn("deep-setup --remove", res.stderr)
        self.assertTrue(self.sudoers_path.exists())
        self.assertTrue((self.cfg_dir / "bin/oma-server").exists())

    def test_uninstall_with_tty_removes_helper_and_sudoers(self):
        if not shutil.which("script"):
            self.skipTest("no script")
        self.run_script("install.sh")
        self.install_helper()
        subprocess.run(["script", "-qec", f"bash {ROOT / 'uninstall.sh'}", "/dev/null"], input="\n",
                       capture_output=True, text=True, env=self.env(), timeout=60)
        self.assertFalse(self.helper_path.exists())
        self.assertFalse(self.sudoers_path.exists())
        self.assertFalse((self.cfg_dir / "bin").exists())


class FollowUpFixTests(DeepSandbox):
    """PR #3 review fixes: Quill Q1-Q5, Sam S1-S3."""

    def helper_calls(self):
        return [c.split("deep-helper ", 1)[1] for c in self.calls()
                if "deep-helper " in c and c.startswith("sudo") and "-l -l" not in c]

    def deep_log(self):
        p = self.deep_dir / "deep.log"
        return p.read_text() if p.exists() else ""

    # ---- Q1: /etc/sudoers.d is root 0750, the user cannot see the rule ----
    def test_q1_enter_works_when_sudoers_dir_unreadable(self):
        self.install_helper()
        sd = self.sudoers_path.parent
        sd.chmod(0o000)
        try:
            res = self.cli("enable", "--deep")
        finally:
            sd.chmod(0o755)
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")

    def test_q1_without_grant_still_refuses(self):
        self.install_helper(grant=False)
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0)
        self.assertIsNone(self.deep_state())

    def test_q1_setup_checks_sudoers_symlink_as_root(self):
        self.sudoers_path.symlink_to("/etc/passwd")
        res = self.cli_tty("deep-setup", answers="y\n")
        self.assertNotEqual(res.rc, 0, res.plain)
        self.assertIn("symlink", res.plain)
        self.assertIn(f"sudo test -L {self.sudoers_path}", self.calls())
        self.assertFalse(self.helper_path.exists())

    def test_q1_remove_with_tty_clears_rule_even_when_helper_missing(self):
        self.install_helper(grant=False)
        self.helper_path.unlink()
        self.helper_path.parent.rmdir()
        res = self.cli_tty("deep-setup", "--remove")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertFalse(self.sudoers_path.exists(), "orphan sudoers rule must still be removed as root")

    def test_q1_uninstall_detects_install_by_helper_dir(self):
        subprocess.run(["bash", str(ROOT / "install.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                       env=self.env(), timeout=60)
        self.helper_path.parent.mkdir(parents=True)
        res = subprocess.run(["bash", str(ROOT / "uninstall.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, env=self.env(), timeout=60)
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("deep-setup --remove", res.stderr)

    # ---- Q2: never kill the fresh Hyprland ----
    def test_q2_exit_with_session_back_never_stops_session_units(self):
        self.install_helper()
        self.write_deep_state()
        (self.s / "inhibit").touch()
        # root revert timer already started SDDM and Hyprland is up
        res = self.cli("disable")
        self.assertEqual(res.returncode, 0, res.plain)
        calls = self.calls()
        self.assertFalse(any("stop graphical-session.target" in c for c in calls), calls)
        self.assertFalse(any("reset-failed" in c and "wayland-wm" in c for c in calls), calls)
        self.assertNotIn("dm-start", self.helper_calls())
        self.assertNotIn("dm-restart", self.helper_calls())
        self.assertTrue(self.is_active("user", "wayland-wm@hyprland.desktop.service"))
        self.assertIsNone(self.deep_state())

    def test_q2_exit_with_session_activating_never_stops_it(self):
        self.install_helper()
        self.write_deep_state()
        self.set_active("user", "wayland-wm@hyprland.desktop.service", False)
        act = self.s / "user-activating"
        act.mkdir()
        (act / "wayland-wm@hyprland.desktop.service").touch()
        self.cli("disable")
        calls = self.calls()
        self.assertFalse(any("stop graphical-session.target" in c for c in calls), calls)
        self.assertNotIn("dm-start", self.helper_calls())

    def test_q2_post_boot_hook_detaches_via_systemd_run(self):
        self.write_deep_state(state="DEEP_SERVER")
        write_executable(self.bin / "oma-server", f"""#!/usr/bin/env bash
echo "oma-server $*" >> "{self.log}"
""")
        subprocess.run(["bash", str(ROOT / "hooks/post-boot.d/99-server-profile-check.sh")],
                       capture_output=True, text=True, env=self.env(), timeout=20)
        calls = self.calls()
        i_run = next(i for i, c in enumerate(calls) if c.startswith("systemd-run --user")
                     and "--unit=oma-server-deep-postboot" in c and c.endswith("__deep-post-boot"))
        self.assertIn("oma-server __deep-post-boot", calls[i_run + 1:])

    def test_q2_status_flags_stale_exiting(self):
        self.install_helper()
        self.write_deep_state(state="DEEP_EXITING")
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual(st["health"], "DEGRADED")
        self.assertIn("stale DEEP_EXITING", st["health_hint"])
        plain = self.cli("status").plain
        self.assertIn("stale DEEP_EXITING", plain)

    def test_q2_status_not_stale_while_lock_held(self):
        self.install_helper()
        self.write_deep_state(state="DEEP_EXITING")
        lock = self.deep_dir / "deep.lock"
        holder = subprocess.Popen(["flock", str(lock), "sleep", "5"])
        try:
            import time
            time.sleep(0.3)
            st = json.loads(self.cli("status", "--json").stdout)
        finally:
            holder.kill()
        self.assertEqual(st["health"], "OK")

    # ---- Q3: hyprctl IPC error vs empty list ----
    def test_q3_ipc_error_after_close_is_reported_as_such(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "t", "pid": 9}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="yes\n\n",
                           extra_env={"OMA_TEST_CLOSE_BREAKS_IPC": "1"})
        self.assertEqual(res.rc, 1, res.plain)
        self.assertIn("IPC error", self.last_deep()["reason"])
        self.assertNotIn("uwsm stop", self.calls())

    def test_q3_transient_ipc_error_is_retried(self):
        self.install_helper()
        (self.s / "hypr-fail-once").touch()
        res = self.cli("enable", "--deep")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")

    # ---- Q4: uwsm TransactionIsDestructive ----
    def test_q4_uwsm_destructive_transaction_retried_once(self):
        self.install_helper()
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_UWSM_FAIL_ONCE": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.calls().count("uwsm stop"), 2)
        self.assertIn("TransactionIsDestructive", self.deep_log())
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")

    def test_q4_uwsm_persistent_failure_still_rolls_back(self):
        self.install_helper()
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_UWSM_FAIL": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        self.assertEqual(self.calls().count("uwsm stop"), 2)
        self.assertIsNone(self.deep_state())

    # ---- Q5 cosmetics ----
    def test_q5_instant_dm_start_failure_reason(self):
        self.install_helper()
        self.write_deep_state()
        self.enter_desktop_down()
        res = self.cli("disable", extra_env={"OMA_TEST_DMSTART_FAIL": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        log = self.deep_log()
        self.assertIn("DEEP_DEGRADED (dm-start failed)", log)
        self.assertNotIn("within", log.split("DEEP_DEGRADED", 1)[1].splitlines()[0])

    def test_q5_transition_line_uses_real_prior_state(self):
        self.install_helper()
        self.write_deep_state(state="DEEP_DEGRADED")
        self.enter_desktop_down()
        res = self.cli("disable")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("DEEP_DEGRADED -> HOST_LAPTOP", res.plain)
        self.assertNotIn("DEEP_SERVER -> HOST_LAPTOP", res.plain)

    def test_q5_remove_without_tty_keeps_allowed_when_refusing(self):
        self.install_helper()
        res = self.cli("deep-setup", "--remove")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("allowed = true", self.cfg.read_text())
        self.assertTrue(self.helper_path.exists())

    def test_q5_remove_without_tty_when_nothing_visible(self):
        res = self.cli("deep-setup", "--remove")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("allowed = false", self.cfg.read_text())

    # ---- S1: OMA_SERVER_TEST_ROOT is test-only ----
    def assert_guard(self, res, needle):
        self.assertEqual(res.returncode, 2, res.plain)
        self.assertIn(needle, res.plain)
        self.assertFalse(any(c.startswith(("sudo", "pkexec")) for c in self.calls()))

    def test_s1_prefix_without_test_mode_refused(self):
        self.install_helper()
        self.assert_guard(self.cli("status", extra_env={"OMA_SERVER_TEST_MODE": ""}), "test-only")
        self.assert_guard(self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_MODE": ""}), "test-only")

    def test_s1_prefix_refused_as_root(self):
        self.assert_guard(self.cli("status", extra_env={"OMA_TEST_FAKE_ROOT": "1"}), "refused as root")

    def test_s1_symlinked_prefix_refused(self):
        link = self.base / "rootlink"
        link.symlink_to(self.root)
        self.assert_guard(self.cli("status", extra_env={"OMA_SERVER_TEST_ROOT": str(link)}), "real, user-owned")
        self.assert_guard(self.cli("status", extra_env={"OMA_SERVER_TEST_ROOT": "relative/dir"}), "real, user-owned")

    def test_s1_real_sudo_on_path_refused(self):
        real = shutil.which("sudo", path="/usr/bin:/bin:/usr/local/bin")
        if not real:
            self.skipTest("no real sudo on this host")
        res = self.cli("status", extra_env={"PATH": f"/usr/bin:/bin:{self.bin}"})
        self.assertEqual(res.returncode, 2, res.plain)
        self.assertIn("real sudo reachable", res.plain)

    def test_s1_uninstall_guarded_too(self):
        env = self.env({"OMA_SERVER_TEST_MODE": ""})
        res = subprocess.run(["bash", str(ROOT / "uninstall.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, env=env, timeout=60)
        self.assertEqual(res.returncode, 2, res.stdout + res.stderr)
        self.assertIn("test-only", res.stderr)

    def test_s1_worker_env_forwarding_gated_on_test_mode(self):
        src = (ROOT / "lib/deep.sh").read_text()
        self.assertIn('[[ "${OMA_SERVER_TEST_MODE:-}" == 1 ]] && fwd+=(OMA_SERVER_TEST_MODE OMA_SERVER_TEST_ROOT)', src)
        base = src.split("local -a fwd=(", 1)[1].split(")", 1)[0]
        self.assertNotIn("OMA_SERVER_TEST_ROOT", base)

    # ---- S2: generated sudoers rule + pinned helper ----
    def plugin_copy(self):
        dst = self.base / "plugin"
        for sub in ("bin", "lib", "libexec", "templates", "config"):
            shutil.copytree(ROOT / sub, dst / sub, symlinks=True)
        return dst

    def test_s2_template_equals_generated_rule(self):
        out = subprocess.run(["bash", "-c", 'source lib/ui.sh; source lib/config.sh; source lib/deep.sh; deep_sudoers_expected'],
                             cwd=ROOT, capture_output=True, text=True, env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)}, timeout=10)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout, SUDOERS.read_text())

    def test_s2_helper_hash_is_pinned(self):
        import hashlib
        pinned = re.search(r'DEEP_HELPER_SHA256="([0-9a-f]{64})"', (ROOT / "lib/deep.sh").read_text()).group(1)
        self.assertEqual(pinned, hashlib.sha256(HELPER.read_bytes()).hexdigest(),
                         "update DEEP_HELPER_SHA256 in lib/deep.sh after changing the helper")

    def test_s2_one_byte_template_change_refused_before_sudo(self):
        plug = self.plugin_copy()
        tpl = plug / "templates/sudoers-oma-server-deep"
        tpl.write_text(tpl.read_text().replace("dm-stop,", "dm-stop ,", 1))
        res = subprocess.run(["script", "-qec", f"{plug / 'bin/oma-server'} deep-setup; echo __RC=$?", "/dev/null"],
                             input="y\n", capture_output=True, text=True, env=self.env(), timeout=60)
        out = ANSI_RE.sub("", res.stdout + res.stderr)
        self.assertIn("__RC=1", out, out)
        self.assertIn("differs from the rule", out)
        self.assertFalse(any(c.startswith("sudo") for c in self.calls()), self.calls())
        self.assertFalse(self.helper_path.exists())

    def test_s2_modified_helper_refused_before_sudo(self):
        plug = self.plugin_copy()
        h = plug / "libexec/oma-server-deep-helper"
        h.write_text(h.read_text() + "\n# x\n")
        res = subprocess.run(["script", "-qec", f"{plug / 'bin/oma-server'} deep-setup; echo __RC=$?", "/dev/null"],
                             input="y\n", capture_output=True, text=True, env=self.env(), timeout=60)
        out = ANSI_RE.sub("", res.stdout + res.stderr)
        self.assertIn("__RC=1", out, out)
        self.assertIn("pinned helper hash", out)
        self.assertFalse(any(c.startswith("sudo") for c in self.calls()))

    def test_s2_staged_file_compared_before_activation(self):
        res = self.cli_tty("deep-setup", answers="y\n", extra_env={"OMA_TEST_STAGE_TAMPER": "1"})
        self.assertNotEqual(res.rc, 0, res.plain)
        self.assertIn("does not match the generated rule", res.plain)
        self.assertFalse(self.sudoers_path.exists())
        self.assertFalse(any(c.startswith("sudo mv") for c in self.calls()))
        self.assertEqual(list(self.sudoers_path.parent.iterdir()), [])

    def test_s2_installed_sudoers_is_generated_text(self):
        res = self.cli_tty("deep-setup", answers="y\n")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(self.sudoers_path.read_text(), SUDOERS.read_text())

    # ---- S3: no group/world-writable helper or folder ----
    def test_s3_group_writable_helper_dir_refused(self):
        self.install_helper()
        self.helper_path.parent.chmod(0o775)
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIsNone(self.deep_state())
        self.assertNotIn("dm-stop", self.helper_calls())

    def test_s3_world_writable_helper_or_parent_refused(self):
        self.install_helper()
        self.helper_path.chmod(0o757)
        self.assertNotEqual(self.cli("enable", "--deep").returncode, 0)
        self.helper_path.chmod(0o755)
        (self.root / "usr/local/lib").chmod(0o777)
        self.assertNotEqual(self.cli("enable", "--deep").returncode, 0)
        (self.root / "usr/local/lib").chmod(0o755)
        self.assertEqual(self.cli("enable", "--deep").returncode, 0)


class FollowUpFixTests2(DeepSandbox):
    """PR #3 second VM pass: Quill B1-B5, Sam N1."""

    def helper_calls(self):
        return [c.split("deep-helper ", 1)[1] for c in self.calls()
                if "deep-helper " in c and c.startswith("sudo") and "-l -l" not in c]

    def deep_log(self):
        p = self.deep_dir / "deep.log"
        return p.read_text() if p.exists() else ""

    def run_script(self, name, extra=None, tty=False):
        env = self.env(extra)
        if tty:
            return subprocess.run(["script", "-qec", f"bash {ROOT / name}; echo __RC=$?", "/dev/null"], input="\n",
                                  capture_output=True, text=True, env=env, timeout=60)
        return subprocess.run(["bash", str(ROOT / name)], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, env=env, timeout=60)

    # ---- B1: session-bound processes in nested uwsm cgroups ----
    def test_b1_lists_nested_scopes_and_wm_service_but_not_hyprland(self):
        self.install_helper()
        cg = self.base / "cgroup"
        uid = os.getuid()
        mgr = cg / f"user.slice/user-{uid}.slice/user@{uid}.service"
        scope = mgr / "app.slice/app-graphical.slice/app-Hyprland-agent-1.scope"
        wm = mgr / "session.slice/wayland-wm@hyprland.desktop.service"
        scope.mkdir(parents=True)
        wm.mkdir(parents=True)
        fake_hypr = self.base / "Hyprland"
        shutil.copy(shutil.which("sleep"), fake_hypr)
        agent = subprocess.Popen(["sleep", "30"])
        child = subprocess.Popen(["tail", "-f", "/dev/null"])
        hypr = subprocess.Popen([str(fake_hypr), "30"])
        try:
            (scope / "cgroup.procs").write_text(f"{agent.pid}\n")
            (wm / "cgroup.procs").write_text(f"{hypr.pid}\n{child.pid}\n")
            res = self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
        finally:
            for pr in (agent, child, hypr):
                pr.kill(); pr.wait()
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("session-bound processes will also stop", res.plain)
        self.assertIn(f"sleep (pid {agent.pid})", res.plain)
        self.assertIn(f"tail (pid {child.pid})", res.plain)
        self.assertNotIn(f"pid {hypr.pid}", res.plain)

    def test_b1_no_warning_without_session_bound_work(self):
        self.install_helper()
        cg = self.base / "cgroup"
        uid = os.getuid()
        (cg / f"user.slice/user-{uid}.slice/user@{uid}.service/app.slice").mkdir(parents=True)
        res = self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertNotIn("session-bound", res.plain)

    # ---- B2: orphaned sudoers rule ----
    def orphan(self):
        self.install_helper(grant=False)
        self.helper_path.unlink()
        self.helper_path.parent.rmdir()

    def test_b2_uninstall_detects_orphaned_rule(self):
        self.run_script("install.sh")
        self.orphan()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 1, res.stdout + res.stderr)
        self.assertIn("deep-setup --remove", res.stderr)
        self.assertIn("sudo -n -l", self.calls())
        self.assertTrue((self.cfg_dir / "bin/oma-server").exists())

    def test_b2_uninstall_with_tty_removes_orphaned_rule(self):
        if not shutil.which("script"):
            self.skipTest("no script")
        self.run_script("install.sh")
        self.orphan()
        self.run_script("uninstall.sh", tty=True)
        self.assertFalse(self.sudoers_path.exists())
        self.assertFalse((self.cfg_dir / "bin").exists())

    def test_b2_remove_without_tty_refuses_on_orphaned_rule(self):
        self.orphan()
        res = self.cli("deep-setup", "--remove")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("interactive terminal", res.plain)
        self.assertTrue(self.sudoers_path.exists())

    def test_b2_uninstall_warns_when_rule_cannot_be_checked(self):
        self.run_script("install.sh")
        (self.s / "list-needs-pw").touch()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn(f"sudo rm -f {self.sudoers_path}", res.stderr)

    def test_b2_uninstall_quiet_when_no_rule(self):
        self.run_script("install.sh")
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertNotIn("sudo rm -f", res.stderr)

    # ---- B3: wait for the user job queue to drain ----
    def test_b3_waits_for_queue_to_drain_then_retries(self):
        import threading
        self.install_helper()
        self.write_config(allowed=True, extra="")
        jobs = self.s / "user-jobs"
        jobs.write_text("42 try-omarchy-desktop-ready.service start running\n")
        t = threading.Timer(1.5, lambda: jobs.unlink())
        t.start()
        try:
            res = self.cli("enable", "--deep", extra_env={"OMA_TEST_UWSM_FAIL_ONCE": "1"})
        finally:
            t.cancel()
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.calls().count("uwsm stop"), 2)
        self.assertIn("waiting up to 180s for queued user jobs", self.deep_log())
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")

    def test_b3_rolls_back_naming_the_queued_unit(self):
        self.install_helper()
        src = self.cfg.read_text().replace("job_wait_seconds = 180", "job_wait_seconds = 1")
        self.cfg.write_text(src)
        (self.s / "user-jobs").write_text("42 try-omarchy-desktop-ready.service start running\n")
        res = self.cli("enable", "--deep", extra_env={"OMA_TEST_UWSM_FAIL": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        self.assertIn("a start job is still queued: try-omarchy-desktop-ready.service", self.last_deep()["reason"])
        self.assertIsNone(self.deep_state())

    def test_b3_default_is_documented(self):
        self.assertIn("job_wait_seconds = 180", (ROOT / "config/config.toml").read_text())
        self.assertIn("job_wait_seconds", (ROOT / "README.md").read_text())

    # ---- B4: follow prints deep.log to the end ----
    def test_b4_final_log_line_is_printed(self):
        self.install_helper()
        res = self.cli("enable", "--deep")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("DEEP_SERVER active (MemAvailable now", res.plain)
        out = res.plain
        self.assertLess(out.index("DEEP_SERVER active (MemAvailable now"), out.index("DEEP_SERVER active. Desktop"))

    def test_b4_worker_logs_before_flipping_state(self):
        src = (ROOT / "lib/deep.sh").read_text()
        i_log = src.index('deep_log "DEEP_SERVER active (MemAvailable now')
        i_set = src.index("deep_state_set state '\"DEEP_SERVER\"'", i_log - 400)
        self.assertLess(i_log, i_set)

    # ---- B5: unique post-boot unit ----
    def test_b5_postboot_unit_unique_and_reset_failed_first(self):
        self.write_deep_state(state="DEEP_SERVER")
        write_executable(self.bin / "oma-server", f"""#!/usr/bin/env bash
echo "oma-server $*" >> "{self.log}"
""")
        hook = ["bash", str(ROOT / "hooks/post-boot.d/99-server-profile-check.sh")]
        subprocess.run(hook, capture_output=True, env=self.env(), timeout=20)
        subprocess.run(hook, capture_output=True, env=self.env(), timeout=20)
        calls = self.calls()
        units = [re.search(r"--unit=(\S+)", c).group(1) for c in calls if c.startswith("systemd-run --user")]
        self.assertEqual(len(units), 2, calls)
        self.assertNotEqual(units[0], units[1])
        boot8 = pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().replace("-", "")[:8]
        for u in units:
            self.assertTrue(u.startswith(f"oma-server-deep-postboot-{boot8}-"), u)
        i_reset = calls.index("systemctl --user reset-failed oma-server-deep-postboot*")
        i_run = next(i for i, c in enumerate(calls) if c.startswith("systemd-run --user"))
        self.assertLess(i_reset, i_run)
        self.assertIn("--collect", calls[i_run])

    # ---- N1: real sudo must not be reachable in test mode ----
    def test_n1_symlink_to_real_sudo_refused(self):
        real = shutil.which("sudo", path="/usr/bin:/bin:/usr/local/bin")
        if not real:
            self.skipTest("no real sudo on this host")
        shim = self.base / "shim"
        shim.mkdir()
        (shim / "sudo").symlink_to(real)
        env = {"PATH": f"{shim}:{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"}
        res = self.cli("status", extra_env=env)
        self.assertEqual(res.returncode, 2, res.plain)
        self.assertIn("real sudo reachable", res.plain)
        res2 = self.run_script("uninstall.sh", extra=env)
        self.assertEqual(res2.returncode, 2, res2.stdout + res2.stderr)
        self.assertIn("real sudo reachable", res2.stderr)

    def test_n1_exported_sudo_function_refused(self):
        marker = self.base / "hijacked"
        env = {"BASH_FUNC_sudo%%": f'() {{  touch {marker}; /usr/bin/sudo "$@"; }}'}
        # Via the shebang (bash -p) the function is never imported at all.
        res = self.cli("status", extra_env=env)
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertFalse(marker.exists())
        # Run as plain 'bash uninstall.sh', it re-execs itself under bash -p first (N8),
        # so the function is never imported there either.
        res2 = self.run_script("uninstall.sh", extra=env)
        self.assertNotIn("sudo is a function", res2.stderr)
        self.assertFalse(marker.exists())

    def test_n1_exported_function_dropped_outside_test_mode(self):
        out = subprocess.run(
            ["bash", "-c", 'source lib/ui.sh; source lib/config.sh; source lib/deep.sh; type -t sudo || echo none'],
            cwd=ROOT, capture_output=True, text=True, timeout=10,
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.home), "BASH_FUNC_sudo%%": "() {  echo hijacked; }"})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertNotIn("function", out.stdout)

    def test_n1_root_owned_or_setuid_stub_refused(self):
        real_true = os.path.realpath(shutil.which("true"))
        if os.stat(real_true).st_uid != 0:
            self.skipTest("/usr/bin/true is not root-owned here")
        shim = self.base / "shim"
        shim.mkdir()
        (shim / "pkexec").symlink_to(real_true)
        res = self.cli("status", extra_env={"PATH": f"{shim}:{self.bin}:/usr/bin:/bin"})
        self.assertEqual(res.returncode, 2, res.plain)
        self.assertIn("real pkexec reachable", res.plain)


class FollowUpFixTests3(DeepSandbox):
    """PR #3 third VM pass: Quill N1-N4 + close-apps UX, Sam INFO-1 (bash -p)."""

    def cgroup(self):
        cg = self.base / "cgroup"
        uid = os.getuid()
        mgr = cg / f"user.slice/user-{uid}.slice/user@{uid}.service"
        wm = mgr / "session.slice/wayland-wm@hyprland.desktop.service"
        wm.mkdir(parents=True)
        return cg, wm

    def spawn(self, *argv, **kw):
        pr = subprocess.Popen(list(argv), **kw)
        self.addCleanup(lambda: (pr.kill(), pr.wait()))
        return pr

    def children(self, pid):
        import time
        for _ in range(50):
            out = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
            if out:
                return [int(x) for x in out]
            time.sleep(0.05)
        self.fail(f"no children of {pid}")

    # ---- N1: no flood from the bar and Omarchy helpers ----
    def test_n1_skips_shell_descendants_and_omarchy_helpers(self):
        self.install_helper()
        cg, wm = self.cgroup()
        bash = shutil.which("bash")
        fake_qs = self.base / "quickshell"
        shutil.copy(bash, fake_qs)
        qs = self.spawn(str(fake_qs), "-c", "sleep 30 & bash -lc 'sleep 30' & wait")
        qs_kids = self.children(qs.pid)
        omarchy = self.base / "omarchy"
        (omarchy / "bin").mkdir(parents=True)
        helper = omarchy / "bin/display-sync"
        helper.write_text("sleep 30\nsleep 1\n")
        hs = self.spawn(bash, str(helper))
        hs_kids = self.children(hs.pid)
        fake_socat = self.base / "socat"
        shutil.copy(shutil.which("sleep"), fake_socat)
        so = self.spawn(str(fake_socat), "30")
        agent = self.spawn("tail", "-f", "/dev/null")
        pids = [qs.pid, *qs_kids, hs.pid, *hs_kids, so.pid, agent.pid]
        (wm / "cgroup.procs").write_text("".join(f"{p}\n" for p in pids))
        res = self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg), "OMARCHY_PATH": str(omarchy)})
        self.assertEqual(res.returncode, 0, res.plain)
        listed = re.findall(r"- (\S+) \(pid (\d+)\)", res.plain)
        self.assertEqual(listed, [("tail", str(agent.pid))], res.plain)

    def test_n1_prints_and_n_more_instead_of_silent_cut(self):
        self.install_helper()
        cg, wm = self.cgroup()
        agents = [self.spawn("tail", "-f", "/dev/null") for _ in range(23)]
        (wm / "cgroup.procs").write_text("".join(f"{a.pid}\n" for a in agents))
        res = self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(len(re.findall(r"- tail \(pid \d+\)", res.plain)), 20)
        self.assertIn("...and 3 more", res.plain)

    # ---- N2: follower outlasts job wait + exit wait ----
    def follow_seconds(self, extra=""):
        src = self.cfg.read_text()
        if extra:
            for k, v in extra.items():
                src = re.sub(rf"^{k} = \d+", f"{k} = {v}", src, flags=re.M)
            self.cfg.write_text(src)
        out = subprocess.run(["bash", "-c", f'source lib/ui.sh; source lib/config.sh; source lib/deep.sh; deep_follow_seconds "{self.cfg}"'],
                             cwd=ROOT, capture_output=True, text=True, timeout=10,
                             env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)})
        self.assertEqual(out.returncode, 0, out.stderr)
        return int(out.stdout.strip())

    def test_n2_follow_deadline_covers_job_and_exit_wait(self):
        self.assertEqual(self.follow_seconds(), 180 + 1 + 60)   # sandbox config: exit_wait_seconds = 1
        self.assertEqual(self.follow_seconds({"job_wait_seconds": 600, "exit_wait_seconds": 45}), 705)
        self.assertEqual(self.follow_seconds({"job_wait_seconds": 9999}), 180 + 45 + 60)
        src = (ROOT / "lib/deep.sh").read_text()
        self.assertIn('deep_follow_enter "$config_file"', src)
        # INFO-5: the env override is validated, then falls back to the computed deadline.
        self.assertIn('[[ "$follow_max" =~ ^[0-9]+$ ]] || follow_max=$(deep_follow_seconds "$config_file")', src)

    # ---- N4: status flags allowed-but-missing helper ----
    def test_n4_status_degraded_when_allowed_but_helper_missing(self):
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertTrue(st["deep_allowed"])
        self.assertFalse(st["deep_helper_ok"])
        self.assertEqual(st["health"], "DEGRADED")
        self.assertIn("deep helper missing", st["health_hint"])
        self.assertIn("deep helper missing", self.cli("status").plain)

    def test_n4_status_ok_when_helper_present_or_not_allowed(self):
        self.install_helper()
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertTrue(st["deep_helper_ok"])
        self.assertEqual(st["health"], "OK")
        self.helper_path.unlink()
        self.write_config(allowed=False)
        st2 = json.loads(self.cli("status", "--json").stdout)
        self.assertEqual(st2["health"], "OK")
        self.assertNotIn("deep helper missing", self.cli("status").plain)

    # ---- --close-apps: one confirmation ----
    def test_close_apps_single_confirmation(self):
        self.install_helper()
        self.set_clients([{"class": "foot", "title": "t", "pid": 9}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="yes\n")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertNotIn("Press Enter", res.plain)
        self.assertLess(res.plain.index("No --timeout"), res.plain.index("Type 'yes'"))
        self.assertEqual(res.plain.count("No --timeout"), 1)
        self.assertEqual(self.deep_state()["state"], "DEEP_SERVER")

    def test_no_windows_without_timeout_still_asks_enter_once(self):
        self.install_helper()
        res = self.cli_tty("enable", "--deep", answers="\n")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(res.plain.count("Press Enter"), 1)

    # ---- Sam INFO-1: bash -p entrypoints ----
    def test_info1_entrypoints_use_bash_p(self):
        for f in ("bin/oma-server", "bin/omarchy-server-mode", "uninstall.sh", "hooks/post-boot.d/99-server-profile-check.sh"):
            first = (ROOT / f).read_text().splitlines()[0]
            self.assertEqual(first, "#!/usr/bin/env -S bash -p", f)
        self.assertEqual((ROOT / "bin/oma-server").read_bytes(), (ROOT / "bin/omarchy-server-mode").read_bytes())

    def test_info1_shadowed_type_and_realpath_do_not_bypass_guard(self):
        real = shutil.which("sudo", path="/usr/bin:/bin:/usr/local/bin")
        if not real:
            self.skipTest("no real sudo on this host")
        env = self.env({
            "PATH": f"/usr/bin:/bin:{self.bin}",
            "BASH_FUNC_type%%": "() {  echo file; }",
            "BASH_FUNC_realpath%%": f"() {{  echo {self.base}/fake-sudo; }}",
            "BASH_FUNC_stat%%": "() {  echo 1000; }",
            "BASH_FUNC_unset%%": "() {  :; }",
        })
        for argv in ([str(OMA_BIN), "status"], [str(ROOT / "bin/omarchy-server-mode"), "status"], [str(ROOT / "uninstall.sh")]):
            res = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(res.returncode, 2, f"{argv}: {res.stdout}{res.stderr}")
            self.assertIn("real sudo reachable", res.stderr)

    def test_info1_hook_ignores_exported_functions(self):
        marker = self.base / "hijacked"
        self.write_deep_state(state="DEEP_SERVER")
        write_executable(self.bin / "oma-server", f"""#!/usr/bin/env bash
echo "oma-server $*" >> "{self.log}"
""")
        env = self.env({"BASH_FUNC_systemd-run%%": f"() {{  touch {marker}; }}",
                        "BASH_FUNC_jq%%": f"() {{  touch {marker}; }}"})
        res = subprocess.run([str(ROOT / "hooks/post-boot.d/99-server-profile-check.sh")], capture_output=True,
                             text=True, env=env, timeout=20)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse(marker.exists())
        self.assertIn("oma-server __deep-post-boot", self.calls())


class FollowUpFixTests4(DeepSandbox):
    """PR #3 fourth VM pass: Quill N5-N8 + window descendants, Sam INFO-1..3."""

    def cgroup(self):
        cg = self.base / "cgroup"
        uid = os.getuid()
        wm = cg / f"user.slice/user-{uid}.slice/user@{uid}.service/session.slice/wayland-wm@hyprland.desktop.service"
        wm.mkdir(parents=True)
        return cg, wm

    def spawn(self, *argv):
        pr = subprocess.Popen(list(argv))
        self.addCleanup(lambda: (pr.kill(), pr.wait()))
        return pr

    def children(self, pid):
        import time
        for _ in range(50):
            out = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
            if out:
                return [int(x) for x in out]
            time.sleep(0.05)
        self.fail(f"no children of {pid}")

    # ---- N5: exited pids: no errors, not listed ----
    def test_n5_exited_pid_is_silent_and_not_listed(self):
        self.install_helper()
        cg, wm = self.cgroup()
        gone = subprocess.Popen(["true"]); gone.wait()
        agent = self.spawn("tail", "-f", "/dev/null")
        (wm / "cgroup.procs").write_text(f"{gone.pid}\n{agent.pid}\n")
        res = self.cli("enable", "--deep", extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertNotIn("No such file", res.plain)
        self.assertNotIn(f"pid {gone.pid})", res.plain)
        self.assertIn(f"tail (pid {agent.pid})", res.plain)

    def test_n5_helper_check_guards_unreadable_cmdline(self):
        src = (ROOT / "lib/deep.sh").read_text()
        body = src.split("_deep_proc_is_omarchy_helper() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('[[ -r "/proc/$pid/cmdline" ]] || return 1', body)
        self.assertIn("} 2>/dev/null", body)

    # ---- cosmetic: descendants of listed windows are not repeated ----
    def test_window_descendants_not_listed(self):
        self.install_helper()
        cg, wm = self.cgroup()
        fake_foot = self.base / "foot"
        shutil.copy(shutil.which("bash"), fake_foot)
        foot = self.spawn(str(fake_foot), "-c", "sleep 30 & wait")
        kid = self.children(foot.pid)[0]
        agent = self.spawn("tail", "-f", "/dev/null")
        (wm / "cgroup.procs").write_text(f"{kid}\n{agent.pid}\n")
        self.set_clients([{"class": "foot", "title": "t", "pid": foot.pid}])
        res = self.cli_tty("enable", "--deep", "--close-apps", answers="yes\n",
                           extra_env={"OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
        self.assertEqual(res.rc, 0, res.plain)
        self.assertNotIn(f"(pid {kid})", res.plain)
        self.assertIn(f"tail (pid {agent.pid})", res.plain)

    # ---- N8: entrypoints re-exec under bash -p when run as `bash file` ----
    def test_n8_hook_run_as_bash_file_drops_functions(self):
        marker = self.base / "hijacked"
        self.write_deep_state(state="DEEP_SERVER")
        write_executable(self.bin / "oma-server", f"""#!/usr/bin/env bash
echo "oma-server $*" >> "{self.log}"
""")
        env = self.env({"BASH_FUNC_systemd-run%%": f"() {{  touch {marker}; }}",
                        "BASH_FUNC_jq%%": f"() {{  touch {marker}; }}",
                        "BASH_FUNC_flock%%": f"() {{  touch {marker}; }}"})
        res = subprocess.run(["bash", str(ROOT / "hooks/post-boot.d/99-server-profile-check.sh")],
                             capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse(marker.exists(), "exported functions must not run in the hook")
        self.assertIn("oma-server __deep-post-boot", self.calls())

    def test_n8_cli_and_uninstall_run_as_bash_file_reexec(self):
        real = shutil.which("sudo", path="/usr/bin:/bin:/usr/local/bin")
        if not real:
            self.skipTest("no real sudo on this host")
        env = self.env({"PATH": f"/usr/bin:/bin:{self.bin}", "BASH_FUNC_type%%": "() {  echo file; }",
                        "BASH_FUNC_realpath%%": f"() {{  echo {self.root}; }}",
                        "BASH_FUNC_stat%%": "() {  echo %d; }" % os.getuid()})
        for argv in (["bash", str(OMA_BIN), "status"], ["bash", str(ROOT / "uninstall.sh")]):
            res = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=60)
            self.assertEqual(res.returncode, 2, f"{argv}: {res.stdout}{res.stderr}")
            self.assertIn("real sudo reachable", res.stderr)

    def test_n8_reexec_line_is_first_body_line(self):
        line = '[[ "${BASH_SOURCE[0]}" != "$0" || $- == *p* ]] || exec /usr/bin/env -S bash -p -- "$0" "$@"'
        for f in ("bin/oma-server", "bin/omarchy-server-mode", "uninstall.sh", "hooks/post-boot.d/99-server-profile-check.sh"):
            body = [l for l in (ROOT / f).read_text().splitlines()[1:] if l.strip() and not l.startswith("#")]
            self.assertEqual(body[0], line, f)

    # ---- Sam INFO-3: fallback children run under bash -p ----
    def test_info3_transition_children_use_bash_p(self):
        src = (ROOT / "lib/transition.sh").read_text()
        self.assertNotIn('bash -c "', src)
        self.assertEqual(src.count('bash -p -c "'), 3)


LAUNCHER = ROOT / "libexec/oma-server-deep-shell"


class DeepShellLauncherTests(unittest.TestCase):
    """libexec/oma-server-deep-shell login: tty1 + DEEP_SERVER only, falls back to the plain shell."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oma-deep-shell-")
        self.base = pathlib.Path(self.tmp.name)
        self.home = self.base / "home"
        self.cfg = self.home / ".config/omarchy/plugins/server-mode/config.toml"
        self.cfg.parent.mkdir(parents=True)
        self.state = self.home / ".local/state/oma-server/deep.json"
        self.state.parent.mkdir(parents=True)
        self.log = self.base / "tui.log"
        self.log.touch()
        # Minimal PATH: only what the launcher needs, so host-installed TUIs never leak in.
        self.tools = self.base / "tools"
        self.tools.mkdir()
        for b in ("awk", "jq", "stty", "cat", "env", "bash", "sh", "clear", "tput"):
            real = shutil.which(b)
            if real:
                (self.tools / b).symlink_to(real)
        self.stubs = self.base / "stubs"
        self.stubs.mkdir()
        write_executable(self.stubs / "tty", '#!/usr/bin/env bash\necho "${OMA_TEST_TTY:-/dev/tty1}"\n')
        self.write_config("none")
        self.write_state("DEEP_SERVER")

    def tearDown(self):
        self.tmp.cleanup()

    def write_config(self, shell, command=""):
        src = (ROOT / "config/config.toml").read_text()
        src = src.replace('shell = "none"', f'shell = "{shell}"').replace('shell_command = ""', f'shell_command = "{command}"')
        self.cfg.write_text(src)

    def write_state(self, state):
        self.state.write_text(json.dumps({"state": state}))

    def stub_tui(self, name, rc=0):
        write_executable(self.stubs / name, f'#!/usr/bin/env bash\necho "{name}${{*:+ $*}}" >> "{self.log}"\nexit {rc}\n')

    def tui_calls(self):
        return self.log.read_text().splitlines()

    def login(self, keys="", extra=None):
        if not shutil.which("script"):
            self.skipTest("util-linux 'script' not available")
        env = {"PATH": f"{self.stubs}:{self.tools}", "HOME": str(self.home), "TERM": "dumb",
               "OMA_DEEP_SHELL_WAIT": "0.3"}
        if extra:
            env.update(extra)
        # Keep stdin open (no EOF) unless keys are sent: an EOF would reach the pty as ^D,
        # which read -n1 counts as a key press. Output goes to a file to avoid pipe stalls.
        import time
        outf = self.base / "login.out"
        with open(outf, "w") as fh:
            proc = subprocess.Popen([shutil.which("script"), "-qec", f"{LAUNCHER} login; echo __RC=$?", "/dev/null"],
                                    stdin=subprocess.PIPE, stdout=fh, stderr=subprocess.STDOUT, text=True, env=env)
            if keys:
                proc.stdin.write(keys)
                proc.stdin.flush()
            deadline = time.time() + 30
            while proc.poll() is None and time.time() < deadline:
                time.sleep(0.05)
            if proc.poll() is None:
                proc.kill()
            proc.stdin.close()
            proc.wait()
        text_out = outf.read_text(errors="replace")
        res = subprocess.CompletedProcess(proc.args, proc.returncode, text_out, "")
        out = ANSI_RE.sub("", res.stdout + res.stderr)
        m = re.search(r"__RC=(\d+)", out)
        res.rc = int(m.group(1)) if m else -1
        res.plain = out
        return res

    def test_default_none_is_a_plain_shell(self):
        for name in ("tmux", "btop", "tuios", "zellij"):
            self.stub_tui(name)
        res = self.login()
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(self.tui_calls(), [])
        self.assertNotIn("oma-server:", res.plain)

    def test_shipped_default_is_none(self):
        self.assertIn('shell = "none"', (ROOT / "config/config.toml").read_text())
        self.assertIn('shell_command = ""', (ROOT / "config/config.toml").read_text())

    def test_each_value_launches_its_program(self):
        expected = {"tmux": "tmux new-session -A -s deep", "btop": "btop", "tuios": "tuios",
                    "zellij": "zellij attach --create deep"}
        for name, argv in expected.items():
            with self.subTest(shell=name):
                self.log.write_text("")
                self.stub_tui(name)
                self.write_config(name)
                res = self.login()
                self.assertEqual(res.rc, 0, res.plain)
                self.assertEqual(self.tui_calls(), [argv])
                self.assertIn(f"Starting {name}", res.plain)
                self.assertIn("plain shell", res.plain)

    def test_custom_runs_shell_command(self):
        self.write_config("custom", f"echo custom-ran >> {self.log}")
        res = self.login()
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(self.tui_calls(), ["custom-ran"])

    def test_custom_without_command_falls_back(self):
        self.write_config("custom", "")
        res = self.login()
        self.assertEqual(res.rc, 0, res.plain)
        self.assertIn("not usable", res.plain)

    def test_missing_binary_falls_back_to_plain_shell(self):
        for name in ("tmux", "btop", "tuios", "zellij"):
            with self.subTest(shell=name):
                self.write_config(name)
                res = self.login()
                self.assertEqual(res.rc, 0, res.plain)
                self.assertIn(f"'{name}' is not installed; staying in the plain shell", res.plain)

    def test_crash_or_quit_returns_to_plain_shell(self):
        self.stub_tui("btop", rc=3)
        self.write_config("btop")
        res = self.login()
        self.assertEqual(res.rc, 0, res.plain)
        self.assertIn("btop ended with code 3", res.plain)
        self.assertIn("You are in the plain shell", res.plain)

    def test_any_key_skips(self):
        self.stub_tui("tmux")
        self.write_config("tmux")
        res = self.login(keys="x")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertIn("Skipped tmux", res.plain)
        self.assertEqual(self.tui_calls(), [])

    def test_noop_off_tty1_over_ssh_nested_or_outside_deep(self):
        self.stub_tui("tmux")
        self.write_config("tmux")
        cases = {
            "tty2": {"OMA_TEST_TTY": "/dev/tty2"},
            "pts": {"OMA_TEST_TTY": "/dev/pts/3"},
            "ssh_connection": {"SSH_CONNECTION": "10.0.0.2 5000 10.0.0.1 22"},
            "ssh_tty": {"SSH_TTY": "/dev/pts/1"},
            "nested_tmux": {"TMUX": "/tmp/tmux-1000/default,1,0"},
            "nested_self": {"OMA_DEEP_SHELL_ACTIVE": "1"},
        }
        for label, extra in cases.items():
            with self.subTest(case=label):
                res = self.login(extra=extra)
                self.assertEqual(res.rc, 0, res.plain)
                self.assertEqual(self.tui_calls(), [], label)
                self.assertNotIn("oma-server:", res.plain)
        for state in ("DEEP_ENTERING", "DEEP_EXITING", "DEEP_DEGRADED"):
            with self.subTest(state=state):
                self.write_state(state)
                self.login()
                self.assertEqual(self.tui_calls(), [])
        self.state.unlink()
        self.login()
        self.assertEqual(self.tui_calls(), [])

    def test_noop_without_a_terminal(self):
        self.stub_tui("tmux")
        self.write_config("tmux")
        res = subprocess.run([str(LAUNCHER), "login"], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                             env={"PATH": f"{self.stubs}:{self.tools}", "HOME": str(self.home)}, timeout=10)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.tui_calls(), [])

    def test_invalid_value_falls_back(self):
        for bad in ("byobu", "rm -rf", "TMUX", ""):
            with self.subTest(value=bad):
                self.write_config(bad)
                res = self.login()
                self.assertEqual(res.rc, 0, res.plain)
                self.assertEqual(self.tui_calls(), [])
                if bad:
                    self.assertIn("not usable", res.plain)

    def test_wait_value_is_validated(self):
        self.stub_tui("tmux")
        self.write_config("tmux")
        marker = self.base / "pwned"
        res = self.login(extra={"OMA_DEEP_SHELL_WAIT": f"$(touch {marker})"})
        self.assertFalse(marker.exists())
        self.assertIn("Starting tmux in 3 s", res.plain)

    def test_byobu_is_not_offered(self):
        for f in ("libexec/oma-server-deep-shell", "lib/deep.sh", "config/config.toml", "README.md", "bin/oma-server"):
            self.assertNotIn("byobu", (ROOT / f).read_text(), f)


    # ---- seventh pass (Quill @ 7bc6ec3) ----
    def stub_clear(self):
        write_executable(self.stubs / "clear", f'#!/usr/bin/env bash\necho CLEARED >> "{self.log}"\n')

    def test_failure_does_not_clear_screen(self):
        self.stub_clear()
        self.write_config("custom", "bash -c 'echo boom-error >&2; exit 3'")
        res = self.login()
        self.assertIn("boom-error", res.plain)
        self.assertIn("ended with code 3", res.plain)
        self.assertNotIn("CLEARED", self.tui_calls())

    def test_clean_exit_still_clears(self):
        self.stub_clear()
        self.stub_tui("btop")
        self.write_config("btop")
        self.login()
        self.assertIn("CLEARED", self.tui_calls())

    def test_missing_custom_program_stays_in_plain_shell(self):
        self.write_config("custom", "FOO=1 no-such-prog-xyz -d 2")
        res = self.login()
        self.assertIn("custom command 'no-such-prog-xyz' is not installed", res.plain)
        self.assertNotIn("Starting custom", res.plain)


class DeepShellCliTests(DeepSandbox):
    """oma-server deep-shell [name]: config + managed login-profile block."""

    def profile(self, name=".bash_profile"):
        return self.home / name

    def test_list_shows_default_none(self):
        res = self.cli("deep-shell")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertRegex(res.plain, r"\* none\s+plain console")
        for c in ("tmux", "btop", "tuios", "zellij", "custom"):
            self.assertIn(c, res.plain)

    def test_set_tmux_adds_block_and_none_removes_it(self):
        self.profile().write_text("export FOO=1\n")
        res = self.cli("deep-shell", "tmux")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn('shell = "tmux"', self.cfg.read_text())
        prof = self.profile().read_text()
        self.assertIn("# >>> oma-server deep shell >>>", prof)
        self.assertIn(f'"{ROOT}/libexec/oma-server-deep-shell" login', prof)
        self.assertIn("/dev/tty1", prof)
        self.assertTrue(prof.startswith("export FOO=1\n"))
        # idempotent: setting again keeps exactly one block
        self.cli("deep-shell", "btop")
        self.assertEqual(self.profile().read_text().count(">>> oma-server deep shell >>>"), 1)
        res2 = self.cli("deep-shell", "none")
        self.assertEqual(res2.returncode, 0, res2.plain)
        self.assertIn('shell = "none"', self.cfg.read_text())
        self.assertEqual(self.profile().read_text(), "export FOO=1\n")

    def test_none_by_default_touches_no_profile(self):
        self.cli("deep-shell", "none")
        self.assertFalse(self.profile().exists())

    def test_zsh_uses_zprofile(self):
        res = self.cli("deep-shell", "tuios", extra_env={"SHELL": "/usr/bin/zsh"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("oma-server deep shell", self.profile(".zprofile").read_text())
        self.assertFalse(self.profile().exists())

    def test_each_supported_value_is_accepted(self):
        for c in ("tmux", "btop", "tuios", "zellij"):
            with self.subTest(shell=c):
                res = self.cli("deep-shell", c)
                self.assertEqual(res.returncode, 0, res.plain)
                self.assertIn(f'shell = "{c}"', self.cfg.read_text())

    def test_missing_program_warns_but_sets(self):
        res = self.cli("deep-shell", "tuios", extra_env={"PATH": f"{self.bin}:/usr/bin:/bin"})
        if shutil.which("tuios", path="/usr/bin:/bin"):
            self.skipTest("tuios installed on host")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("not installed yet", res.plain)

    def test_invalid_value_rejected_and_config_unchanged(self):
        before = self.cfg.read_text()
        for bad in ("byobu", "bash", "--command"):
            res = self.cli("deep-shell", bad)
            self.assertNotEqual(res.returncode, 0, bad)
            self.assertIn("Unknown deep shell", res.plain)
        self.assertEqual(self.cfg.read_text(), before)
        self.assertFalse(self.profile().exists())

    def test_custom_requires_safe_command(self):
        self.assertNotEqual(self.cli("deep-shell", "custom").returncode, 0)
        for bad in ('echo "x"', "a\\b", "a\nb"):
            res = self.cli("deep-shell", "custom", "--command", bad)
            self.assertNotEqual(res.returncode, 0, bad)
        self.assertIn('shell = "none"', self.cfg.read_text())
        res = self.cli("deep-shell", "custom", "--command", "htop -d 20")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn('shell_command = "htop -d 20"', self.cfg.read_text())
        self.assertIn('shell = "custom"', self.cfg.read_text())

    def test_symlinked_profile_is_refused(self):
        real = self.base / "real_profile"
        real.write_text("")
        self.profile().symlink_to(real)
        res = self.cli("deep-shell", "tmux")
        self.assertNotEqual(res.returncode, 0)
        self.assertEqual(real.read_text(), "")

    def test_uninstall_removes_the_block(self):
        subprocess.run(["bash", str(ROOT / "install.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                       env=self.env(), timeout=60)
        self.profile().write_text("export FOO=1\n")
        installed = self.cfg_dir / "bin/oma-server"
        subprocess.run([str(installed), "deep-shell", "tmux"], capture_output=True, env=self.env(), timeout=30)
        self.assertIn("oma-server deep shell", self.profile().read_text())
        res = subprocess.run(["bash", str(ROOT / "uninstall.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, env=self.env(), timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.profile().read_text(), "export FOO=1\n")


class ConsoleFixAndHardeningTests(DeepSandbox):
    """Helper console fix (getty@tty1 + chvt 1), Sam INFO-4/INFO-5, quickshell_strategy honesty."""

    def test_helper_console_fix(self):
        src = HELPER.read_text()
        self.assertIn('readonly GETTY_UNIT="getty@tty1.service"', src)
        dm_stop = src.split("    dm-stop)", 1)[1].split(";;", 1)[0]
        self.assertLess(dm_stop.index('stop "$DM_UNIT"'), dm_stop.index('start "$GETTY_UNIT"'))
        self.assertIn("/usr/bin/chvt 1", dm_stop)
        dm_start = src.split("dm_start() {", 1)[1].split("}", 1)[0]
        self.assertLess(dm_start.index('stop "$GETTY_UNIT"'), dm_start.index('start "$DM_UNIT"'))
        dm_restart = src.split("    dm-restart)", 1)[1].split(";;", 1)[0]
        self.assertLess(dm_restart.index('stop "$GETTY_UNIT"'), dm_restart.index('restart "$DM_UNIT"'))
        self.assertIn("getty@tty1.service", src.split("set -euo pipefail", 1)[0], "contract comment must list getty@tty1")

    def test_helper_hash_pin_matches_console_fix(self):
        import hashlib
        self.assertEqual(hashlib.sha256(HELPER.read_bytes()).hexdigest(),
                         "cc3309fdf39ae83d402b52cdd2f87a13fdc4f995efd38c1477de688c8df5a989")

    def test_allowlist_and_sudoers_unchanged(self):
        self.assertEqual((ROOT / "templates/sudoers-oma-server-deep").read_text().count("deep-helper "), 9)
        self.assertNotIn("getty", (ROOT / "templates/sudoers-oma-server-deep").read_text())

    def test_info4_sourced_entry_script_does_not_replace_caller(self):
        for f in ("bin/oma-server", "uninstall.sh", "hooks/post-boot.d/99-server-profile-check.sh"):
            line = [l for l in (ROOT / f).read_text().splitlines()[1:] if l.strip() and not l.startswith("#")][0]
            probe = self.base / "probe.sh"
            probe.write_text(line + '\necho "flags=$-"\n')
            sourced = subprocess.run(["bash", "-c", f'source {probe}; echo CALLER-ALIVE'], capture_output=True, text=True, timeout=10)
            self.assertIn("CALLER-ALIVE", sourced.stdout, f)
            run = subprocess.run(["bash", str(probe)], capture_output=True, text=True, timeout=10)
            self.assertRegex(run.stdout, r"flags=\S*p", f"{f}: 'bash file' must re-exec under -p")

    def test_info5_follow_seconds_env_is_validated(self):
        self.install_helper()
        marker = self.base / "pwned"
        res = self.cli("enable", "--deep", extra_env={"OMA_DEEP_FOLLOW_SECONDS": f"a[$(touch {marker})]"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertFalse(marker.exists())

    def test_quickshell_strategy_other_than_sigstop_warns(self):
        src = self.cfg.read_text().replace('quickshell_strategy = "sigstop"', 'quickshell_strategy = "none"')
        self.cfg.write_text(src)
        res = self.cli("diff")
        self.assertIn('quickshell_strategy = "none" is not supported', res.plain)

    def test_readme_is_honest_about_homelab_panel(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("The panel is a `HOST_LAPTOP` control.", readme)
        self.assertIn('only "sigstop" is implemented', readme)
        self.assertNotIn("Primary mode toggle (`Enable Homelab Mode` / `Restore Desktop Mode`)", readme)
        for img in ("preview.png", "assets/screenshots/03-deep-console-login-crop@2x.png"):
            self.assertIn(img, readme)
            self.assertTrue((ROOT / img).is_file(), img)
        self.assertIn("re-run `oma-server deep-setup`", readme)


class SixthPassTests(DeepSandbox):
    """Sam re-review @ 80f5a9e: L1 detached exit on tty1, L2 unterminated block, INFO-6/7/8, temp-file traps."""

    BEGIN = "# >>> oma-server deep shell >>>"
    END = "# <<< oma-server deep shell <<<"

    def profile(self, name=".bash_profile"):
        return self.home / name

    def on_tty1(self):
        # The sandbox runs on a pty; name that pty as "the console" (test mode only).
        self._console = True

    def cli_tty(self, *args, answers="", extra_env=None):
        if not shutil.which("script"):
            self.skipTest("util-linux 'script' not available")
        prefix = 'export OMA_DEEP_TEST_CONSOLE="$(tty)"; ' if getattr(self, "_console", False) else ""
        cmd = prefix + " ".join([str(OMA_BIN), *args]) + "; echo __RC=$?"
        res = subprocess.run(["script", "-qec", cmd, "/dev/null"], input=answers, capture_output=True,
                             text=True, env=self.env(extra_env), timeout=60)
        out = ANSI_RE.sub("", res.stdout + res.stderr)
        m = re.search(r"__RC=(\d+)", out)
        res.rc = int(m.group(1)) if m else -1
        res.plain = out
        return res

    def exit_runs(self):
        return [c for c in self.calls() if c.startswith("systemd-run --user") and "--unit=oma-server-deep-exit" in c]

    def ready_to_exit(self, **state):
        self.install_helper()
        self.write_deep_state(**state)
        self.enter_desktop_down()

    # ---- L1 ----
    def test_l1_helper_ignores_hup_before_any_privileged_call(self):
        src = HELPER.read_text()
        body = src.split("set -euo pipefail", 1)[1]
        self.assertIn("trap '' HUP", body)
        first_cmd = min(body.index(x) for x in ('"$SYSTEMCTL"', "$SYSTEMCTL ", "/usr/bin/chvt") if x in body)
        self.assertLess(body.index("trap '' HUP"), first_cmd)
        self.assertLess(body.index("trap '' HUP"), body.index("readonly SYSTEMCTL"))

    def test_l1_helper_survives_sighup(self):
        # The helper shape (set -euo + trap '' HUP) keeps running when HUP arrives.
        prelude = HELPER.read_text().split("PATH=", 1)[0]
        script = prelude + 'kill -HUP $$\nsleep 0.1\necho survived\n'
        res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=10)
        self.assertEqual(res.stdout.strip(), "survived", res.stderr)

    def test_l1_disable_on_tty1_runs_detached(self):
        self.ready_to_exit(timeout_seconds=120)
        self.on_tty1()
        res = self.cli_tty("disable")
        self.assertEqual(res.rc, 0, res.plain)
        runs = self.exit_runs()
        self.assertEqual(len(runs), 1, self.calls())
        self.assertTrue(runs[0].endswith("__deep-exit-worker"), runs[0])
        self.assertIn("--setenv=OMA_SERVER_TEST_ROOT=", runs[0])
        calls = self.calls()
        i_run = calls.index(runs[0])
        i_dm = next(i for i, c in enumerate(calls) if c.endswith("deep-helper dm-start"))
        self.assertLess(i_run, i_dm, "the exit sequence must run inside the detached unit")
        self.assertIn("detached unit", res.plain)
        self.assertIn("Desktop restored", res.plain)
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.last_deep()["result"], "exited")
        self.assertTrue(self.is_active("sys", "display-manager.service"))

    def test_l1_inside_deep_shell_runs_detached(self):
        self.ready_to_exit()
        res = self.cli("disable", extra_env={"OMA_DEEP_SHELL_ACTIVE": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(len(self.exit_runs()), 1)
        self.assertIsNone(self.deep_state())

    def test_l1_off_console_stays_in_foreground(self):
        self.ready_to_exit()
        res = self.cli_tty("disable")        # a pty, not tty1
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(self.exit_runs(), [])
        self.assertIsNone(self.deep_state())

    def test_l1_auto_timeout_stays_in_foreground_even_on_tty1(self):
        self.ready_to_exit(timeout_seconds=120)
        self.on_tty1()
        res = self.cli_tty("disable", "--auto-timeout")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(self.exit_runs(), [])

    def test_l1_systemd_run_failure_falls_back_to_foreground(self):
        self.ready_to_exit()
        res = self.cli("disable", extra_env={"OMA_DEEP_SHELL_ACTIVE": "1", "OMA_TEST_SYSTEMD_RUN_FAIL": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("running in the foreground", res.plain)
        self.assertIsNone(self.deep_state())

    def test_l1_detached_failure_reports_degraded(self):
        self.ready_to_exit()
        (self.s / "autologin_works").unlink()
        res = self.cli("disable", extra_env={"OMA_DEEP_SHELL_ACTIVE": "1"})
        self.assertEqual(res.returncode, 1, res.plain)
        self.assertIn("Desktop did not come back", res.plain)
        self.assertEqual(self.deep_state()["state"], "DEEP_DEGRADED")
        self.assertTrue((self.s / "inhibit").exists())

    def test_l1_rescue_on_tty1_runs_exit_detached(self):
        self.ready_to_exit()
        self.on_tty1()
        res = self.cli_tty("rescue")
        self.assertEqual(res.rc, 0, res.plain)
        self.assertEqual(len(self.exit_runs()), 1)
        self.assertIsNone(self.deep_state())

    # ---- L2 ----
    def sam_profile(self):
        text = f"a\n{self.BEGIN}\nx\nuser-line-after\n"
        self.profile().write_text(text)
        return text

    def test_l2_unterminated_block_is_left_untouched_by_deep_shell(self):
        text = self.sam_profile()
        for choice in ("none", "tmux"):
            with self.subTest(choice=choice):
                res = self.cli("deep-shell", choice)
                self.assertNotEqual(res.returncode, 0, res.plain)
                self.assertIn("without a matching end marker", res.plain)
                self.assertEqual(self.profile().read_text(), text)
        self.assertEqual(sorted(p.name for p in self.home.iterdir() if p.name.startswith(".bash_profile")),
                         [".bash_profile"])

    def test_l2_unterminated_block_is_left_untouched_by_uninstall(self):
        text = self.sam_profile()
        res = subprocess.run(["bash", str(ROOT / "uninstall.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, env=self.env(), timeout=60)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("without a matching end marker", ANSI_RE.sub("", res.stdout + res.stderr))
        self.assertEqual(self.profile().read_text(), text)

    def test_l2_stray_end_or_nested_begin_is_refused(self):
        for text in (f"a\n{self.END}\n{self.BEGIN}\nb\n", f"{self.BEGIN}\n{self.BEGIN}\n{self.END}\nkeep\n"):
            with self.subTest(text=text):
                self.profile().write_text(text)
                self.assertNotEqual(self.cli("deep-shell", "none").returncode, 0)
                self.assertEqual(self.profile().read_text(), text)

    def test_l2_wellformed_block_still_removed(self):
        self.profile().write_text(f"a\n\n{self.BEGIN}\nx\n{self.END}\nuser-line-after\n")
        res = self.cli("deep-shell", "none")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.profile().read_text(), "a\nuser-line-after\n")

    # ---- INFO-6 / INFO-7 / INFO-8 ----
    def test_info6_config_mode_is_preserved(self):
        os.chmod(self.cfg, 0o600)
        self.assertEqual(self.cli("deep-shell", "custom", "--command", "htop").returncode, 0)
        self.assertEqual(stat.S_IMODE(self.cfg.stat().st_mode), 0o600)
        os.chmod(self.cfg, 0o640)
        self.assertEqual(self.cli("deep-shell", "none").returncode, 0)
        self.assertEqual(stat.S_IMODE(self.cfg.stat().st_mode), 0o640)

    def test_info7_symlinked_profile_with_block_is_refused_by_none(self):
        real = self.base / "dotfiles_profile"
        text = f"a\n{self.BEGIN}\nx\n{self.END}\n"
        real.write_text(text)
        self.profile().symlink_to(real)
        res = self.cli("deep-shell", "none")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("symlink", res.plain)
        self.assertTrue(self.profile().is_symlink())
        self.assertEqual(real.read_text(), text)

    def test_info8_new_bash_profile_sources_profile_first(self):
        self.assertFalse(self.profile().exists())
        self.assertEqual(self.cli("deep-shell", "tmux").returncode, 0)
        lines = self.profile().read_text().splitlines()
        self.assertEqual(lines[1], '[ -f "$HOME/.profile" ] && . "$HOME/.profile"')
        self.assertLess(1, lines.index(self.BEGIN))
        # the source line survives removing the block
        self.assertEqual(self.cli("deep-shell", "none").returncode, 0)
        self.assertIn('. "$HOME/.profile"', self.profile().read_text())
        self.assertNotIn(self.BEGIN, self.profile().read_text())
        # and it really runs ~/.profile in a bash login shell
        (self.home / ".profile").write_text(f'touch "{self.base}/profile-ran"\n')
        subprocess.run(["bash", "-lc", "true"], env=self.env(), capture_output=True, timeout=10)
        self.assertTrue((self.base / "profile-ran").exists())

    def test_info8_existing_profile_and_zprofile_get_no_source_line(self):
        self.profile().write_text("export FOO=1\n")
        self.cli("deep-shell", "tmux")
        self.assertNotIn(".profile\"", self.profile().read_text())
        self.cli("deep-shell", "btop", extra_env={"SHELL": "/usr/bin/zsh"})
        self.assertNotIn(".profile\"", self.profile(".zprofile").read_text())

    # ---- temp-file cleanup on signals ----
    def awk_killer(self, marker):
        write_executable(self.bin / "awk", f"""#!/usr/bin/env bash
if [[ "$*" == *"{marker}"* ]]; then kill -TERM "$PPID"; /usr/bin/awk "$@"; exit $?; fi
exec /usr/bin/awk "$@"
""")

    def test_signal_during_config_rewrite_removes_temp_file(self):
        self.awk_killer("function emit")
        before = self.cfg.read_text()
        res = self.cli("deep-shell", "tmux")
        self.assertEqual(res.returncode, -signal.SIGTERM, res.plain)
        self.assertEqual([p.name for p in self.cfg_dir.iterdir() if p.name.startswith("config.toml.")], [])
        self.assertEqual(self.cfg.read_text(), before)

    def test_signal_during_profile_rewrite_removes_temp_file(self):
        self.profile().write_text(f"a\n{self.BEGIN}\nx\n{self.END}\n")
        self.awk_killer("held { print")
        res = self.cli("deep-shell", "none")
        self.assertEqual(res.returncode, -signal.SIGTERM, res.plain)
        self.assertEqual([p.name for p in self.home.iterdir() if p.name.startswith(".bash_profile.")], [])

    def test_signal_during_uninstall_rewrite_removes_temp_file(self):
        self.profile().write_text(f"a\n{self.BEGIN}\nx\n{self.END}\n")
        self.awk_killer("h{print")
        res = subprocess.run(["bash", str(ROOT / "uninstall.sh")], stdin=subprocess.DEVNULL, capture_output=True,
                             text=True, env=self.env(), timeout=60)
        self.assertEqual(res.returncode, -signal.SIGTERM, res.stdout + res.stderr)
        self.assertEqual([p.name for p in self.home.iterdir() if p.name.startswith(".bash_profile.")], [])


class StaleHelperTests(DeepSandbox):
    """Quill M-new-1: an installed helper whose sha256 differs from DEEP_HELPER_SHA256 is not trusted."""

    def make_stale(self):
        self.install_helper()
        os.chmod(self.helper_path, 0o755)
        with open(self.helper_path, "a") as fh:
            fh.write("# older build\n")

    def helper_calls(self):
        return [c for c in self.calls() if "deep-helper " in c and c.startswith("sudo") and "-l -l" not in c]

    def test_enable_deep_refuses_stale_helper(self):
        self.make_stale()
        res = self.cli("enable", "--deep")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("outdated", res.plain)
        self.assertIn("oma-server deep-setup", res.plain)
        self.assertIsNone(self.deep_state())
        self.assertEqual(self.helper_calls(), [])
        self.assertFalse(any(c.startswith("systemd-run") for c in self.calls()))
        self.assertTrue(self.is_active("sys", "display-manager.service"))

    def test_status_degraded_with_setup_hint(self):
        self.make_stale()
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertFalse(st["deep_helper_ok"])
        self.assertEqual(st["health"], "DEGRADED")
        self.assertIn("deep helper outdated", st["health_hint"])
        self.assertIn("deep-setup", st["health_hint"])
        plain = self.cli("status").plain
        self.assertIn("DEGRADED", plain)
        self.assertIn("deep helper outdated", plain)

    def test_diff_deep_shows_outdated(self):
        self.make_stale()
        res = self.cli("diff", "--deep")
        self.assertIn("OUTDATED helper", res.plain)
        self.assertNotIn("ok (passwordless", res.plain)

    def test_current_helper_is_ok(self):
        self.install_helper()
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertTrue(st["deep_helper_ok"])
        self.assertEqual(st["health"], "OK")
        self.assertIn("ok (passwordless", self.cli("diff", "--deep").plain)

    def test_missing_helper_still_says_missing(self):
        st = json.loads(self.cli("status", "--json").stdout)
        self.assertIn("deep helper missing", st["health_hint"])

    def test_disable_still_works_with_stale_helper(self):
        self.make_stale()
        self.write_deep_state()
        self.enter_desktop_down()
        res = self.cli("disable")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIsNone(self.deep_state())
        self.assertTrue(self.is_active("sys", "display-manager.service"))

    def test_readme_matches_behaviour(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn('"deep helper outdated"', readme)
        self.assertIn("`enable --deep` refuses", readme)
        self.assertNotIn('"deep helper missing". Re-running', readme)


class SeventhPassTests(DeepSandbox):
    """Sam re-review @ 7bc6ec3 (L3, INFO-9, trap restore) and Quill's 7bc6ec3 VM report."""

    BEGIN = "# >>> oma-server deep shell >>>"
    END = "# <<< oma-server deep shell <<<"

    def profile(self):
        return self.home / ".bash_profile"

    def dm_calls(self):
        return [c for c in self.calls() if "deep-helper dm-" in c and c.startswith("sudo")]

    def ready_to_exit(self):
        self.install_helper()
        self.write_deep_state()
        self.enter_desktop_down()

    def run_on_console_fd1_only(self):
        """stdout is the console pty; stdin and stderr are not ttys (INFO-9)."""
        cmd = (f'export OMA_DEEP_TEST_CONSOLE="$(tty)"; {OMA_BIN} disable </dev/null 2>"{self.base}/err.txt";'
               ' echo __RC=$?')
        res = subprocess.run(["script", "-qec", cmd, "/dev/null"], input="", capture_output=True, text=True,
                             env=self.env(), timeout=60)
        return ANSI_RE.sub("", res.stdout + res.stderr)

    # ---- L3 ----
    def test_l3_running_exit_unit_is_followed_not_duplicated(self):
        self.ready_to_exit()
        self.set_active("user", "oma-server-deep-exit.service")
        res = self.cli("disable", extra_env={"OMA_DEEP_FOLLOW_SECONDS": "1"})
        self.assertIn("already running", res.plain)
        self.assertEqual(res.returncode, 4, res.plain)
        self.assertEqual(self.dm_calls(), [])
        self.assertFalse(any(c.startswith("systemd-run") for c in self.calls()))

    def test_l3_running_exit_unit_success_when_state_cleared(self):
        self.ready_to_exit()
        self.set_active("user", "oma-server-deep-exit.service")
        (self.deep_dir / "deep.json").unlink()
        (self.deep_dir / "last-deep.json").write_text('{"result":"exited"}')
        self.write_deep_state()
        # state disappears while following
        import threading, time
        def clear():
            time.sleep(0.5)
            (self.deep_dir / "deep.json").unlink()
        th = threading.Thread(target=clear); th.start()
        res = self.cli("disable", extra_env={"OMA_DEEP_FOLLOW_SECONDS": "5"})
        th.join()
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(self.dm_calls(), [])

    def test_l3_exit_rechecks_state_after_lock(self):
        import fcntl, time
        self.ready_to_exit()
        lock = self.deep_dir / "deep.lock"
        fh = open(lock, "w")
        fcntl.flock(fh, fcntl.LOCK_EX)
        proc = subprocess.Popen([str(OMA_BIN), "disable"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=self.env())
        time.sleep(1.5)                       # the CLI is now waiting in flock -w 10
        (self.deep_dir / "deep.json").unlink()  # the other exit finished
        fcntl.flock(fh, fcntl.LOCK_UN); fh.close()
        out, _ = proc.communicate(timeout=30)
        out = ANSI_RE.sub("", out)
        self.assertEqual(proc.returncode, 0, out)
        self.assertIn("Already restored", out)
        self.assertEqual(self.dm_calls(), [])

    def test_l3_guard_is_right_after_flock(self):
        src = (ROOT / "lib/deep.sh").read_text()
        body = src.split("deep_exit_transaction() {", 1)[1]
        lock_block = body.split('if ! flock -w "$lock_wait" 201; then', 1)[1].split("\n    fi\n", 1)
        first = [l.strip() for l in lock_block[1].splitlines() if l.strip() and not l.strip().startswith("#")][0]
        self.assertTrue(first.startswith("deep_state_exists || { exec 201>&-;"), first)
        # every successful path through the lock block ends at that guard (no state change inside)
        self.assertNotIn("deep_state_set", lock_block[0])
        self.assertNotIn("deep_helper_root", lock_block[0])

    # ---- INFO-9 ----
    def test_info9_console_on_stdout_only_is_detected(self):
        if not shutil.which("script"):
            self.skipTest("util-linux 'script' not available")
        self.ready_to_exit()
        out = self.run_on_console_fd1_only()
        self.assertIn("__RC=0", out)
        self.assertTrue(any("--unit=oma-server-deep-exit" in c for c in self.calls()), self.calls())
        self.assertIsNone(self.deep_state())

    def test_info9_uses_proc_readlink(self):
        src = (ROOT / "lib/deep.sh").read_text().split("deep_on_console() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('t=$(readlink -- "/proc/$$/fd/$fd" 2>/dev/null)', src)
        self.assertNotIn("tty <&", src)

    def test_info9_console_override_needs_test_mode(self):
        self.ready_to_exit()
        env = {"OMA_SERVER_TEST_MODE": "0", "OMA_DEEP_TEST_CONSOLE": "/dev/null"}
        self.cli("disable", extra_env=env)
        self.assertFalse(any("--unit=oma-server-deep-exit" in c for c in self.calls()))

    # ---- trap save/restore ----
    def test_tmp_guard_restores_earlier_traps(self):
        script = f"""
source "{ROOT}/lib/ui.sh" 2>/dev/null || true
source "{ROOT}/lib/deep.sh"
trap 'echo mine-int' INT
trap 'echo mine-term' TERM
deep_tmp_guard /tmp/x1
trap -p INT | grep -q _deep_tmp_on_signal && echo armed
deep_tmp_release
trap -p INT TERM HUP
"""
        res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=self.env(), timeout=10)
        self.assertIn("armed", res.stdout, res.stderr)
        self.assertIn("trap -- 'echo mine-int' SIGINT", res.stdout)
        self.assertIn("trap -- 'echo mine-term' SIGTERM", res.stdout)
        self.assertNotIn("HUP", res.stdout)

    def test_uninstall_restores_earlier_traps(self):
        src = (ROOT / "uninstall.sh").read_text()
        self.assertIn("UNINSTALL_SAVED_TRAPS=$(trap -p INT TERM HUP)", src)
        self.assertIn('eval "$UNINSTALL_SAVED_TRAPS"', src)

    # ---- L-new-1: profile first, config after ----
    def test_refused_profile_leaves_config_unchanged(self):
        self.profile().write_text(f"a\n{self.BEGIN}\nx\n")
        before = self.cfg.read_text()
        for choice in ("btop", "none"):
            with self.subTest(choice=choice):
                res = self.cli("deep-shell", choice)
                self.assertNotEqual(res.returncode, 0, res.plain)
                self.assertEqual(self.cfg.read_text(), before)
        self.assertRegex(self.cli("deep-shell").plain, r"\* none")

    def test_refused_symlink_profile_leaves_config_unchanged(self):
        real = self.base / "dot"; real.write_text("")
        self.profile().symlink_to(real)
        before = self.cfg.read_text()
        self.assertNotEqual(self.cli("deep-shell", "custom", "--command", "htop").returncode, 0)
        self.assertEqual(self.cfg.read_text(), before)

    def test_config_failure_rolls_back_new_profile_block(self):
        self.profile().write_text("export FOO=1\n")
        os.chmod(self.cfg_dir, 0o500)       # mktemp in the config dir fails
        try:
            res = self.cli("deep-shell", "tmux")
        finally:
            os.chmod(self.cfg_dir, 0o755)
        if os.geteuid() == 0:
            self.skipTest("root ignores directory permissions")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("rolled back", res.plain)
        self.assertEqual(self.profile().read_text(), "export FOO=1\n")
        self.assertIn('shell = "none"', self.cfg.read_text())

    # ---- INFO-10: failed `shell` write restores the old shell_command ----
    def test_info10_failed_shell_write_restores_old_command(self):
        self.cfg.write_text(self.cfg.read_text().replace('shell = "none"', 'shell = "custom"')
                            .replace('shell_command = ""', 'shell_command = "htop -d 20"'))
        # awk refuses only the `shell` key rewrite; shell_command writes still work.
        write_executable(self.bin / "awk", """#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "k=shell" ]] && exit 1; done
exec /usr/bin/awk "$@"
""")
        res = self.cli("deep-shell", "custom", "--command", "top -d 2")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("rolled back", res.plain)
        cfg = self.cfg.read_text()
        self.assertIn('shell_command = "htop -d 20"', cfg)
        self.assertNotIn("top -d 2\"", cfg.replace('"htop -d 20"', ""))
        self.assertIn('shell = "custom"', cfg)
        self.assertEqual([p.name for p in self.cfg_dir.iterdir() if p.name.startswith("config.toml.")], [])

    # ---- INFO-11: console override needs the guarded test root ----
    def on_console_probe(self, with_root):
        if not shutil.which("script"):
            self.skipTest("util-linux 'script' not available")
        env = self.env({"OMA_SERVER_TEST_MODE": "1"})
        if not with_root:
            env.pop("OMA_SERVER_TEST_ROOT")
        script = (f'export OMA_DEEP_TEST_CONSOLE="$(tty)"; source "{ROOT}/lib/deep.sh"; '
                  'deep_on_console && echo __CONSOLE=yes || echo __CONSOLE=no')
        res = subprocess.run(["script", "-qec", f"bash -c '{script}'", "/dev/null"], input="",
                             capture_output=True, text=True, env=env, timeout=30)
        return res.stdout + res.stderr

    def test_info11_console_override_ignored_without_test_root(self):
        self.assertIn("__CONSOLE=no", self.on_console_probe(with_root=False))

    def test_info11_console_override_works_with_test_root(self):
        self.assertIn("__CONSOLE=yes", self.on_console_probe(with_root=True))

    # ---- custom command warnings ----
    def test_custom_missing_program_warns(self):
        res = self.cli("deep-shell", "custom", "--command", "FOO=1 no-such-prog-xyz --flag")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("'no-such-prog-xyz' is not installed", res.plain)
        res2 = self.cli("deep-shell", "custom", "--command", "bash -c true")
        self.assertNotIn("not installed", res2.plain)

    # ---- quickshell PID lookup ----
    def test_quickshell_lookup_ignores_omarchy_shell_wrapper(self):
        for f in ("lib/snapshot.sh", "lib/transition.sh"):
            src = (ROOT / f).read_text()
            self.assertNotIn('pgrep -u "$current_uid" -x "omarchy-shell"', src, f)
            self.assertIn('pgrep -o -u "$current_uid" -x "quickshell"', src, f)
        self.assertNotIn('"quickshell|omarchy-shell"', (ROOT / "lib/transition.sh").read_text())

    def test_quickshell_lookup_picks_real_shell_process(self):
        # A long-lived `quickshell` and a transient `omarchy-shell shell ping` wrapper.
        d = self.base / "procs"; d.mkdir()
        qs = d / "quickshell"; wrap = d / "omarchy-shell"
        for f in (qs, wrap):
            write_executable(f, "#!/bin/bash\nsleep 30\n")
        p_qs = subprocess.Popen([str(qs)])
        p_wrap = subprocess.Popen([str(wrap), "shell", "ping"])
        try:
            import time; time.sleep(0.3)
            script = f"""
source "{ROOT}/lib/transition.sh"
get_quickshell_telemetry
"""
            env = self.env(); env["PATH"] = "/usr/bin:/bin"
            res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=10)
            self.assertIn(f"PID: {p_qs.pid}", res.stdout, res.stderr)
            self.assertNotIn(f"PID: {p_wrap.pid}", res.stdout)
        finally:
            p_qs.kill(); p_wrap.kill(); p_qs.wait(); p_wrap.wait()

    # ---- README ----
    def test_readme_documents_wait_and_tuios_daemon(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("OMA_DEEP_SHELL_WAIT", readme)
        self.assertIn("tuios daemon", readme)


class NinthPassTests(DeepSandbox):
    """Quill/Sam notes @ b88c75d: busy-lock disable, shell_command rollback, cgroup-root gate."""

    def dm_calls(self):
        return [c for c in self.calls() if "deep-helper dm-" in c and c.startswith("sudo")]

    def hold_lock_then(self, state, after, release_after=2.0, extra=None):
        """Hold deep.lock with deep.json in `state`; after `release_after` s call after() and release."""
        import fcntl, time
        self.install_helper()
        self.write_deep_state(state=state)
        self.enter_desktop_down()
        fh = open(self.deep_dir / "deep.lock", "w")
        fcntl.flock(fh, fcntl.LOCK_EX)
        env = {"OMA_DEEP_LOCK_WAIT": "1"}
        env.update(extra or {})
        proc = subprocess.Popen([str(OMA_BIN), "disable"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=self.env(env))
        try:
            time.sleep(release_after)
            after()
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN); fh.close()
        out, _ = proc.communicate(timeout=60)
        return proc.returncode, ANSI_RE.sub("", out)

    def test_second_disable_waits_for_running_restore_and_reports_success(self):
        def finish_first():
            (self.deep_dir / "deep.json").unlink()
            (self.deep_dir / "last-deep.json").write_text('{"result":"exited"}')
        rc, out = self.hold_lock_then("DEEP_EXITING", finish_first)
        self.assertEqual(rc, 0, out)
        self.assertIn("already in progress", out)
        self.assertIn("Already restored", out)
        self.assertNotIn("Another deep-mode transition", out)
        self.assertNotRegex(out, r"\bFAIL\b")
        self.assertEqual(self.dm_calls(), [])

    def test_second_disable_retries_when_first_restore_degraded(self):
        def first_degraded():
            self.write_deep_state(state="DEEP_DEGRADED")
        rc, out = self.hold_lock_then("DEEP_EXITING", first_degraded)
        self.assertIn("already in progress", out)
        self.assertEqual(rc, 0, out)                  # it ran the exit itself and succeeded
        self.assertTrue(self.dm_calls(), self.calls())
        self.assertIsNone(self.deep_state())

    def test_second_disable_times_out_without_fail(self):
        rc, out = self.hold_lock_then("DEEP_EXITING", lambda: None, release_after=4.0,
                                      extra={"OMA_DEEP_FOLLOW_SECONDS": "1"})
        self.assertEqual(rc, 4, out)
        self.assertIn("still running", out)
        self.assertNotIn("Another deep-mode transition", out)
        self.assertEqual(self.deep_state()["state"], "DEEP_EXITING")
        self.assertEqual(self.dm_calls(), [])

    def test_disable_during_enter_still_fails(self):
        rc, out = self.hold_lock_then("DEEP_ENTERING", lambda: None, release_after=2.0)
        self.assertEqual(rc, 1, out)
        self.assertIn("Another deep-mode transition (DEEP_ENTERING)", out)
        self.assertEqual(self.dm_calls(), [])

    def test_lock_wait_override_needs_test_root(self):
        src = (ROOT / "lib/deep.sh").read_text()
        self.assertIn('[[ "${OMA_SERVER_TEST_MODE:-}" == 1 && -n "$DEEP_ROOT_PREFIX" && "${OMA_DEEP_LOCK_WAIT:-}" =~ ^[0-9]+$ ]]', src)

    # ---- shell_command rollback drops a key that did not exist ----
    def test_rollback_drops_new_shell_command_key(self):
        cfg = "\n".join(l for l in self.cfg.read_text().splitlines() if not l.strip().startswith("shell_command")) + "\n"
        self.cfg.write_text(cfg)
        write_executable(self.bin / "awk", """#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "k=shell" ]] && exit 1; done
exec /usr/bin/awk "$@"
""")
        res = self.cli("deep-shell", "custom", "--command", "top -d 2")
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("rolled back", res.plain)
        self.assertNotRegex(self.cfg.read_text(), r"(?m)^\s*shell_command\s*=")
        self.assertEqual(self.cfg.read_text(), cfg)
        self.assertEqual([p.name for p in self.cfg_dir.iterdir() if p.name.startswith("config.toml.")], [])

    # ---- INFO-12: fake cgroup root needs the guarded test root ----
    def session_bound(self, with_root):
        cg = self.base / "cgroup"
        uid = os.getuid()
        scope = cg / f"user.slice/user-{uid}.slice/user@{uid}.service/app.slice/app-x-1.scope"
        scope.mkdir(parents=True, exist_ok=True)
        agent = subprocess.Popen(["sleep", "30"])
        try:
            (scope / "cgroup.procs").write_text(f"{agent.pid}\n")
            env = self.env({"OMA_SERVER_TEST_MODE": "1", "OMA_SERVER_TEST_CGROUP_ROOT": str(cg)})
            if not with_root:
                env.pop("OMA_SERVER_TEST_ROOT")
            res = subprocess.run(["bash", "-c", f'source "{ROOT}/lib/deep.sh"; deep_list_session_bound_procs ""'],
                                 capture_output=True, text=True, env=env, timeout=20)
        finally:
            agent.kill(); agent.wait()
        return agent.pid, res.stdout

    def test_info12_cgroup_root_ignored_without_test_root(self):
        pid, out = self.session_bound(with_root=False)
        self.assertNotIn(f"{pid}\tsleep", out)

    def test_info12_cgroup_root_used_with_test_root(self):
        pid, out = self.session_bound(with_root=True)
        self.assertIn(f"{pid}\tsleep", out)

    def test_readme_tuios_is_modal(self):
        self.assertIn("press `i` to start typing", (ROOT / "README.md").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
