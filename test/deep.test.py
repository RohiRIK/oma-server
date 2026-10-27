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
        env = {"BASH_FUNC_sudo%%": '() {  /usr/bin/sudo "$@"; }'}
        res = self.cli("status", extra_env=env)
        self.assertEqual(res.returncode, 2, res.plain)
        self.assertIn("sudo is a function", res.plain)
        self.assertEqual(self.calls(), [])
        res2 = self.run_script("uninstall.sh", extra=env)
        self.assertEqual(res2.returncode, 2, res2.stdout + res2.stderr)
        self.assertIn("sudo is a function", res2.stderr)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
