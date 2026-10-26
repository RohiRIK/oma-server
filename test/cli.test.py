#!/usr/bin/env python3
"""Sandboxed CLI, config, snapshot, and state-transition tests for oma-server."""
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
OMA_BIN = ROOT / "bin/oma-server"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SandboxedCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oma-server-test-")
        self.base = pathlib.Path(self.tmp.name)
        self.bin_dir = self.base / "bin"
        self.run_base = self.base / "runtime"
        self.run_dir = self.run_base / "omarchy-server-mode"
        self.state_dir = self.base / "state"
        self.bin_dir.mkdir(parents=True)
        self.run_base.mkdir(parents=True, mode=0o700)
        self.state_dir.mkdir(parents=True)

        # Stub hyprctl supporting batched JSON queries, Lua hl.config, and Lua hl.dsp.dpms
        write_executable(
            self.bin_dir / "hyprctl",
            f"""#!/usr/bin/env bash
STATE_DIR="{self.state_dir}"
dpms_state="true"
[[ -f "$STATE_DIR/dpms" ]] && dpms_state=$(cat "$STATE_DIR/dpms")
if [[ "$*" == *"--batch"* && "$*" == *"getoption"* ]]; then
    printf '{{"option":"animations:enabled","int":1,"set":true}}\\n'
    printf '{{"option":"decoration:blur:enabled","int":0,"set":true}}\\n'
    printf '{{"option":"decoration:shadow:enabled","int":0,"set":true}}\\n'
    printf '{{"option":"decoration:rounding","int":0,"set":true}}\\n'
    printf '[{{"name":"eDP-1","dpmsStatus":%s}}]\\n' "$dpms_state"
    exit 0
fi
if [[ "$1" == "-j" && "$2" == "monitors" ]]; then
    printf '[{{"name":"eDP-1","dpmsStatus":%s}}]\\n' "$dpms_state"
    exit 0
fi
if [[ "$1" == "eval" ]]; then
    echo "ok"
    exit 0
fi
if [[ "$1" == "dispatch" ]]; then
    if [[ "${{OMA_TEST_FAIL_DPMS_ON:-0}}" == "1" ]] && [[ "$*" == *'action = "enable"'* || "$*" == *"dpms on"* ]]; then
        # Simulate a hung Hyprland IPC socket (coreutils timeout exit code)
        echo "error: IPC timeout" >&2
        exit 124
    fi
    if [[ "$*" == *'action = "disable"'* || "$*" == *"dpms off"* ]]; then
        echo "false" > "$STATE_DIR/dpms"
    elif [[ "$*" == *'action = "enable"'* || "$*" == *"dpms on"* ]]; then
        echo "true" > "$STATE_DIR/dpms"
    fi
    echo "ok"
    exit 0
fi
if [[ "$1" == "reload" ]]; then
    if [[ "${{OMA_TEST_FAIL_RELOAD:-0}}" == "1" ]]; then
        echo "error: IPC timeout" >&2
        exit 124
    fi
    echo "ok"
    exit 0
fi
echo "ok"
""",
        )

        # Stub systemd-inhibit
        write_executable(
            self.bin_dir / "systemd-inhibit",
            f"""#!/usr/bin/env bash
STATE_DIR="{self.state_dir}"
if [[ "${{1:-}}" == "--list" ]]; then
    if [[ -f "$STATE_DIR/inhibit_active" ]]; then
        echo "oma-server 1000 user 1234 systemd-inhibit sleep:idle:handle-lid-switch Omarchy Homelab Workload Active block"
    fi
    exit 0
fi
if [[ "${{OMA_TEST_DENY_INHIBIT:-0}}" == "1" ]]; then
    echo "Failed to inhibit: Interactive authentication required." >&2
    exit 1
fi
echo "1" > "$STATE_DIR/inhibit_active"
trap 'rm -f "$STATE_DIR/inhibit_active"; exit 0' TERM INT
sleep 300
""",
        )

        # Force fallback to setsid in sandbox so systemd --user on host is never touched
        write_executable(
            self.bin_dir / "systemd-run",
            """#!/usr/bin/env bash
exit 1
""",
        )

        # Stub systemctl so host units are never queried or mutated
        write_executable(
            self.bin_dir / "systemctl",
            """#!/usr/bin/env bash
if [[ "$*" == *"is-active"* ]]; then
    if [[ "$*" == *"docker.service"* || "$*" == *"sshd.service"* ]]; then
        exit 0
    fi
    exit 3
fi
exit 0
""",
        )

        # Stub omarchy-shell
        write_executable(
            self.bin_dir / "omarchy-shell",
            """#!/usr/bin/env bash
echo "false"
""",
        )

        # Stub pgrep and pkill so host quickshell is never signaled during sandboxed tests
        write_executable(
            self.bin_dir / "pgrep",
            """#!/usr/bin/env bash
if [[ "$*" == *"quickshell"* || "$*" == *"omarchy-shell"* ]]; then
    exit 1
fi
exec /usr/bin/pgrep "$@"
""",
        )
        write_executable(
            self.bin_dir / "pkill",
            """#!/usr/bin/env bash
if [[ "$*" == *"quickshell"* || "$*" == *"omarchy-shell"* ]]; then
    exit 0
fi
exec /usr/bin/pkill "$@"
""",
        )

    def tearDown(self):
        # Clean up any leftover background sleep from setsid inhibitor/timer in sandbox
        for pid_file in ("inhibitor.pid", "timeout.pid"):
            p = self.run_dir / pid_file
            if p.is_file():
                try:
                    pid = int(p.read_text().strip())
                    os.kill(pid, 15)
                except (ValueError, ProcessLookupError, PermissionError):
                    pass
        self.tmp.cleanup()

    def run_cli(self, *args, extra_env=None, stdin_data=None):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["OMA_SERVER_RUNTIME_BASE"] = str(self.run_base)
        env["OMA_SERVER_RUN_DIR"] = str(self.run_dir)
        env["XDG_CONFIG_HOME"] = str(self.base / "config")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [str(OMA_BIN), *args],
            input=stdin_data,
            capture_output=True,
            text=True,
            env=env,
            timeout=20,
        )

    def assert_box_geometry(self, output: str):
        lines = [ANSI_RE.sub("", line) for line in output.splitlines() if ANSI_RE.sub("", line).strip()]
        self.assertGreater(len(lines), 4)
        for line in lines:
            if line[0] in "┌├└│":
                self.assertEqual(len(line), 78, f"Box row length != 78 ({len(line)}): {line!r}")
                self.assertIn(line[-1], "┐┤┘│", f"Missing right border on row: {line!r}")

    def test_version_and_help_box(self):
        v = self.run_cli("--version")
        self.assertEqual(v.returncode, 0)
        self.assertIn("oma-server v1.1.1", v.stdout)

        h = self.run_cli("--help")
        self.assertEqual(h.returncode, 0)
        self.assert_box_geometry(h.stdout)

    def test_timeout_and_arg_validation(self):
        for bad in ("2s", "8d", "abc"):
            res = self.run_cli("enable", "--dry-run", "--timeout", bad)
            self.assertNotEqual(res.returncode, 0, f"Expected failure for --timeout {bad}")

        missing = self.run_cli("enable", "--timeout")
        self.assertNotEqual(missing.returncode, 0)

        valid = self.run_cli("enable", "--dry-run", "--timeout=7d")
        self.assertEqual(valid.returncode, 0)

        unknown = self.run_cli("bogus-cmd")
        self.assertNotEqual(unknown.returncode, 0)

    def test_status_and_diff_in_host_mode(self):
        st = self.run_cli("status")
        self.assertEqual(st.returncode, 0)
        self.assertIn("HOST_LAPTOP", st.stdout)
        self.assert_box_geometry(st.stdout)

        st_json = self.run_cli("status", "--json")
        self.assertEqual(st_json.returncode, 0)
        payload = json.loads(st_json.stdout)
        self.assertEqual(payload["mode"], "HOST_LAPTOP")
        self.assertFalse(payload["is_homelab"])
        self.assertEqual(payload["health"], "OK")

        diff = self.run_cli("diff")
        self.assertEqual(diff.returncode, 0)
        self.assert_box_geometry(diff.stdout)
        plain_diff = ANSI_RE.sub("", diff.stdout)
        # Verify accurate boolean extraction (false is preserved, not coerced to true)
        self.assertRegex(plain_diff, r"animations:enabled\s+│\s+true")
        self.assertRegex(plain_diff, r"decoration:blur:enabled\s+│\s+false")
        self.assertRegex(plain_diff, r"decoration:shadow:enabled\s+│\s+false")
        self.assertRegex(plain_diff, r"decoration:rounding\s+│\s+0")
        self.assertNotIn("misc:vfr", plain_diff)
        self.assertNotIn("decoration:drop_shadow", plain_diff)

    def test_non_tty_guard_requires_yes_flag(self):
        res = self.run_cli("enable", stdin_data="y\n")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("not a TTY", res.stderr)

    def test_enable_status_disable_and_auto_timeout(self):
        en = self.run_cli("enable", "-y", "--timeout", "30s")
        self.assertEqual(en.returncode, 0, f"enable failed:\n{en.stdout}\n{en.stderr}")
        self.assertTrue((self.run_dir / "active-snapshot.json").is_file())

        st_json = self.run_cli("status", "--json")
        self.assertEqual(st_json.returncode, 0)
        payload = json.loads(st_json.stdout)
        self.assertEqual(payload["mode"], "HOMELAB_MODE")
        self.assertTrue(payload["is_homelab"])
        self.assertEqual(payload["health"], "OK")
        self.assertTrue(payload["inhibitor"].startswith("Active"))
        self.assertIn("OFF", payload["dpms"])

        # Simulate Dead Man's Switch auto-revert (--auto-timeout) without self-kill
        dis = self.run_cli("disable", "--auto-timeout")
        self.assertEqual(dis.returncode, 0, f"disable --auto-timeout failed:\n{dis.stdout}\n{dis.stderr}")
        self.assertFalse((self.run_dir / "active-snapshot.json").exists())
        self.assertFalse(self.run_dir.exists(), "Empty state dir must be removed after a clean disable")

        st_after = json.loads(self.run_cli("status", "--json").stdout)
        self.assertEqual(st_after["mode"], "HOST_LAPTOP")
        self.assertIn("ON", st_after["dpms"])

    def test_polkit_inhibit_denial_fails_honestly_and_rolls_back(self):
        res = self.run_cli("enable", "-y", extra_env={"OMA_TEST_DENY_INHIBIT": "1"})
        self.assertNotEqual(res.returncode, 0, "enable should fail when systemd-inhibit is denied")
        self.assertFalse(
            (self.run_dir / "active-snapshot.json").exists(),
            "Rollback must remove active-snapshot.json when inhibitor fails",
        )
        # systemd-inhibit's own error must survive into the failure message
        self.assertIn("Interactive authentication required", ANSI_RE.sub("", res.stderr))

    def test_disable_fails_and_keeps_state_when_dpms_restore_fails(self):
        en = self.run_cli("enable", "-y")
        self.assertEqual(en.returncode, 0, f"enable failed:\n{en.stdout}\n{en.stderr}")
        snapshot = self.run_dir / "active-snapshot.json"
        self.assertTrue(snapshot.is_file())

        dis = self.run_cli("disable", extra_env={"OMA_TEST_FAIL_DPMS_ON": "1"})
        out = ANSI_RE.sub("", dis.stdout + dis.stderr)
        self.assertNotEqual(dis.returncode, 0, f"disable must fail when DPMS on fails:\n{out}")
        self.assertIn("[ FAIL ] Powering on display panels", out)
        self.assertIn("Restoration incomplete: 1 step(s) failed", out)
        # The final verdict must reach stderr (not be swallowed by the lock-FD close)
        self.assertIn("Desktop restore FAILED", ANSI_RE.sub("", dis.stderr))
        self.assertNotIn("Desktop restored to HOST_LAPTOP", out)
        self.assertTrue(snapshot.is_file(), "Saved snapshot must be kept when a restore step fails")

        # Once Hyprland answers again, a plain retry completes and purges state
        retry = self.run_cli("disable")
        self.assertEqual(retry.returncode, 0, f"retry failed:\n{retry.stdout}\n{retry.stderr}")
        self.assertIn("Desktop restored to HOST_LAPTOP", ANSI_RE.sub("", retry.stdout))
        self.assertFalse(snapshot.exists())

    def test_disable_fails_and_keeps_state_when_reload_times_out(self):
        en = self.run_cli("enable", "-y")
        self.assertEqual(en.returncode, 0, f"enable failed:\n{en.stdout}\n{en.stderr}")
        dis = self.run_cli("disable", extra_env={"OMA_TEST_FAIL_RELOAD": "1"})
        out = ANSI_RE.sub("", dis.stdout + dis.stderr)
        self.assertNotEqual(dis.returncode, 0, out)
        self.assertIn("Reloading Hyprland compositor configuration", out)
        self.assertNotIn("Desktop restored to HOST_LAPTOP", out)
        self.assertTrue((self.run_dir / "active-snapshot.json").is_file())

    def test_rescue_still_completes_when_reload_fails(self):
        en = self.run_cli("enable", "-y")
        self.assertEqual(en.returncode, 0, f"enable failed:\n{en.stdout}\n{en.stderr}")
        res = self.run_cli("rescue", extra_env={"OMA_TEST_FAIL_RELOAD": "1"})
        self.assertEqual(res.returncode, 0, f"rescue must stay best-effort:\n{res.stdout}\n{res.stderr}")
        self.assertFalse(self.run_dir.exists())

    def test_rescue_restores_baseline(self):
        res = self.run_cli("rescue")
        self.assertEqual(res.returncode, 0)
        self.assertFalse(self.run_dir.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
