#!/usr/bin/env python3
"""Sandboxed install.sh / uninstall.sh tests for oma-server.

HOME, XDG_CONFIG_HOME and every system binary the scripts touch (pgrep, pkill,
systemctl, omarchy, omarchy-shell, omarchy-restart-shell) are redirected into a
throwaway directory, so nothing on the host is modified or signaled.
"""
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def write_executable(path: pathlib.Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="oma-server-install-test-")
        self.base = pathlib.Path(self.tmp.name)
        self.home = self.base / "home"
        self.config = self.home / ".config"
        self.bin_dir = self.base / "bin"
        self.log = self.base / "calls.log"
        self.home.mkdir()
        self.bin_dir.mkdir()
        self.log.touch()
        self.target = self.config / "omarchy/plugins/server-mode"

        log = self.log
        # Pretend a shell instance is running when OMA_TEST_SHELL_RUNNING=1
        write_executable(self.bin_dir / "pgrep", f"""#!/usr/bin/env bash
if [[ "$*" == *"quickshell"* || "$*" == *"omarchy-shell"* ]]; then
    if [[ "${{OMA_TEST_SHELL_STATEFUL:-0}}" == "1" ]]; then
        [[ -s "{self.base}/shell-pids" ]] && {{ cat "{self.base}/shell-pids"; exit 0; }}
        exit 1
    fi
    [[ "${{OMA_TEST_SHELL_RUNNING:-0}}" == "1" ]] && {{ echo 4242; exit 0; }}
    exit 1
fi
exec /usr/bin/pgrep "$@"
""")
        write_executable(self.bin_dir / "pkill", f"""#!/usr/bin/env bash
echo "pkill $*" >> "{log}"
exit 0
""")
        write_executable(self.bin_dir / "systemctl", "#!/usr/bin/env bash\nexit 0\n")
        write_executable(self.bin_dir / "omarchy-restart-shell", f"""#!/usr/bin/env bash
echo "restart-shell" >> "{log}"
if [[ "${{OMA_TEST_SHELL_STATEFUL:-0}}" == "1" ]]; then
    # kill mode: the upstream race leaves no shell at all
    if [[ "${{OMA_TEST_RESTART_KILLS_SHELL:-0}}" == "1" ]]; then : > "{self.base}/shell-pids"; else echo 4343 > "{self.base}/shell-pids"; fi
fi
exit 0
""")
        write_executable(self.bin_dir / "hyprctl", f"""#!/usr/bin/env bash
echo "hyprctl $*" >> "{log}"
if [[ "$*" == *omarchy-launch-shell* ]]; then echo 5555 > "{self.base}/shell-pids"; echo ok; fi
exit 0
""")
        # Like the real tools, fail when OMARCHY_PATH is unset (plain SSH)
        write_executable(self.bin_dir / "omarchy-shell", f"""#!/usr/bin/env bash
[[ -n "${{OMARCHY_PATH:-}}" ]] || {{ echo "omarchy-shell: OMARCHY_PATH is not set" >&2; exit 1; }}
if [[ "$1 $2" == "shell ping" ]]; then
    [[ "${{OMA_TEST_PING_FAIL:-0}}" == "1" ]] && exit 1
    if [[ "${{OMA_TEST_SHELL_STATEFUL:-0}}" == "1" ]]; then [[ -s "{self.base}/shell-pids" ]] || exit 1; fi
    exit 0
fi
echo "omarchy-shell $* [OMARCHY_PATH=$OMARCHY_PATH]" >> "{log}"
exit 0
""")
        write_executable(self.bin_dir / "omarchy", f"""#!/usr/bin/env bash
if [[ -z "${{OMARCHY_PATH:-}}" ]]; then
    echo "find: '/shell/plugins': No such file or directory" >&2
    exit 1
fi
echo "omarchy $* [OMARCHY_PATH=$OMARCHY_PATH]" >> "{log}"
if [[ "$1 $2" == "plugin enable" && -n "${{OMA_TEST_SOCK_PROBE:-}}" ]]; then
    [[ -S "$OMA_TEST_SOCK_PROBE" ]] && echo "sock=yes" >> "{log}" || echo "sock=no" >> "{log}"
fi
if [[ "$1 $2" == "plugin enable" && "${{OMA_TEST_ENABLE_FAIL:-0}}" == "1" ]]; then
    echo "error: omarchy-shell IPC timed out" >&2
    exit 1
fi
if [[ "$1 $2" == "plugin enable" && -n "${{OMA_TEST_ENABLE_FAIL_TIMES:-}}" ]]; then
    cnt="{self.base}/enable-fails"
    n=$(cat "$cnt" 2>/dev/null || echo 0)
    if (( n < OMA_TEST_ENABLE_FAIL_TIMES )); then
        echo $((n + 1)) > "$cnt"
        echo "WARN quickshell.ipc: Socket Error QLocalSocket::PeerClosedError" >&2
        exit 1
    fi
fi
exit 0
""")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, name, *args, extra_env=None, graphical=False):
        env = {
            "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.config),
            "TERM": "dumb",
            "XDG_RUNTIME_DIR": str(self.base / "xdg-runtime"),
            "OMA_INSTALL_ENABLE_BACKOFF": "0.01",
            "OMA_INSTALL_IPC_POLL": "0.01",
            "OMA_INSTALL_IPC_WAIT": "0.3",
        }
        if graphical:
            env["WAYLAND_DISPLAY"] = "wayland-1"
            env["HYPRLAND_INSTANCE_SIGNATURE"] = "test-sig"
        if extra_env:
            env.update(extra_env)
        res = subprocess.run(
            ["bash", str(ROOT / name), *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        res.plain = ANSI_RE.sub("", res.stdout + res.stderr)
        return res

    def calls(self):
        return self.log.read_text(encoding="utf-8")

    # --- install.sh -------------------------------------------------------

    def test_install_over_ssh_does_not_restart_shell(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertNotIn("restart-shell", self.calls(), "Shell must not be restarted without a graphical session")
        self.assertIn("omarchy-shell shell rescanPlugins", self.calls())
        self.assertIn("omarchy plugin enable rohirik.oma-server", self.calls())
        self.assertIn("installation complete (bar widget enabled)", res.plain)

    def test_install_defaults_omarchy_path_when_unset(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertNotIn("/shell/plugins", res.plain)
        self.assertIn("omarchy plugin enable rohirik.oma-server --section right [OMARCHY_PATH=/usr/share/omarchy]", self.calls())

    def test_install_respects_existing_omarchy_path(self):
        res = self.run_script(
            "install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1", "OMARCHY_PATH": "/opt/omarchy-dev"}
        )
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("[OMARCHY_PATH=/opt/omarchy-dev]", self.calls())

    def test_install_in_graphical_session_restarts_shell(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1"}, graphical=True)
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("restart-shell", self.calls())

    def enable_calls(self):
        return [c for c in self.calls().splitlines() if c.startswith("omarchy plugin enable")]

    def test_n3_widget_enable_retries_after_peer_closed(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_ENABLE_FAIL_TIMES": "3"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(len(self.enable_calls()), 4)
        self.assertNotIn("FAILED", res.plain)

    def test_n3_waits_for_quickshell_ipc_socket(self):
        import socket, threading
        qs = self.base / "xdg-runtime/quickshell/by-id/abc"
        qs.mkdir(parents=True)
        sock = socket.socket(socket.AF_UNIX)
        def bind():
            sock.bind(str(qs / "ipc.sock"))
        t = threading.Timer(0.1, bind)
        t.start()
        try:
            res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_ENABLE_FAIL_TIMES": "1",
                                                           "OMA_INSTALL_IPC_POLL": "0.05"})
        finally:
            t.cancel(); sock.close()
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertEqual(len(self.enable_calls()), 2)

    def test_n3_gives_up_after_bounded_retries(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_ENABLE_FAIL_TIMES": "99"})
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertEqual(len(self.enable_calls()), 6)
        self.assertIn("PeerClosedError", res.plain)

    def test_n7_restart_that_kills_the_shell_relaunches_it(self):
        (self.base / "shell-pids").write_text("4242\n")
        res = self.run_script("install.sh", graphical=True, extra_env={
            "OMA_TEST_SHELL_STATEFUL": "1", "OMA_TEST_RESTART_KILLS_SHELL": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("relaunching it", res.plain)
        self.assertIn('hyprctl dispatch hl.dsp.exec_cmd("omarchy-launch-shell")', self.calls())
        self.assertEqual((self.base / "shell-pids").read_text().strip(), "5555")
        self.assertIn("omarchy plugin enable rohirik.oma-server", self.calls())

    def test_n7_healthy_restart_does_not_relaunch(self):
        (self.base / "shell-pids").write_text("4242\n")
        res = self.run_script("install.sh", graphical=True, extra_env={"OMA_TEST_SHELL_STATEFUL": "1"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("restart-shell", self.calls())
        self.assertNotIn("omarchy-launch-shell", self.calls())

    def test_n6_stale_socket_is_not_trusted(self):
        import socket, threading, time
        qs = self.base / "xdg-runtime/quickshell"
        stale = qs / "by-id/dead"
        stale.mkdir(parents=True)
        s1 = socket.socket(socket.AF_UNIX); s1.bind(str(stale / "ipc.sock")); s1.close()   # stale, nobody listening
        live = qs / "by-id/live"
        live.mkdir(parents=True)
        (qs / "by-pid").mkdir()
        (qs / "by-pid/4242").symlink_to(live)
        s2 = socket.socket(socket.AF_UNIX)
        t = threading.Timer(0.5, lambda: s2.bind(str(live / "ipc.sock")))
        t.start()
        try:
            res = self.run_script("install.sh", extra_env={
                "OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_PING_FAIL": "1", "OMA_INSTALL_IPC_WAIT": "5",
                "OMA_INSTALL_IPC_POLL": "0.05", "OMA_TEST_SOCK_PROBE": str(qs / "by-pid/4242/ipc.sock")})
        finally:
            t.cancel(); s2.close()
        self.assertEqual(res.returncode, 0, res.plain)
        first = [l for l in self.calls().splitlines() if l.startswith("sock=")][0]
        self.assertEqual(first, "sock=yes", "must wait for the live shell's by-pid socket, not any ipc.sock")

    def test_info2_tuning_vars_are_validated(self):
        marker = self.base / "pwned"
        payload = f"a[$(touch {marker})]"
        res = self.run_script("install.sh", extra_env={
            "OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_ENABLE_FAIL_TIMES": "1",
            "OMA_INSTALL_ENABLE_TRIES": payload, "OMA_INSTALL_ENABLE_BACKOFF": payload,
            "OMA_INSTALL_IPC_POLL": payload, "OMA_INSTALL_IPC_WAIT": "0.3"})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertFalse(marker.exists(), "payload must never be evaluated")
        src = (ROOT / "install.sh").read_text()
        self.assertIn('[[ "$enable_tries" =~ ^[0-9]+$ ]]', src)

    def test_install_reports_widget_enable_failure_honestly(self):
        res = self.run_script(
            "install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1", "OMA_TEST_ENABLE_FAIL": "1"}
        )
        self.assertNotEqual(res.returncode, 0, res.plain)
        self.assertIn("enabling the bar widget FAILED", res.plain)
        self.assertNotIn("installation complete", res.plain)
        # Core files are still installed so the CLI works and the user can retry
        self.assertTrue((self.target / "bin/oma-server").is_file())

    def test_install_without_running_shell_warns_instead_of_claiming_widget(self):
        res = self.run_script("install.sh")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("bar widget NOT registered", res.plain)
        self.assertNotIn("installation complete", res.plain)

    # --- uninstall.sh -----------------------------------------------------

    def _install_with_custom_config(self):
        res = self.run_script("install.sh")
        self.assertEqual(res.returncode, 0, res.plain)
        cfg = self.target / "config.toml"
        cfg.write_text(cfg.read_text(encoding="utf-8") + "\n# user edit\n", encoding="utf-8")
        return cfg

    def test_uninstall_keeps_config_by_default(self):
        cfg = self._install_with_custom_config()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertTrue(cfg.is_file(), "config.toml must be kept by default")
        self.assertIn("# user edit", cfg.read_text(encoding="utf-8"))
        self.assertFalse((self.target / "bin").exists())
        self.assertFalse((self.target / "lib").exists())
        self.assertFalse((self.home / ".local/bin/oma-server").exists())
        self.assertIn("Configuration kept at", res.plain)

        # Reinstall picks the kept configuration back up
        res2 = self.run_script("install.sh")
        self.assertEqual(res2.returncode, 0, res2.plain)
        self.assertIn("# user edit", cfg.read_text(encoding="utf-8"))

    def test_uninstall_disables_widget_with_default_omarchy_path(self):
        self._install_with_custom_config()
        res = self.run_script("uninstall.sh")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("omarchy plugin disable rohirik.oma-server [OMARCHY_PATH=/usr/share/omarchy]", self.calls())

    def test_uninstall_ignores_empty_runtime_dir_in_laptop_mode(self):
        self._install_with_custom_config()
        run_dir = self.base / "runtime/omarchy-server-mode"
        run_dir.mkdir(parents=True)
        res = self.run_script("uninstall.sh", extra_env={"OMA_SERVER_RUN_DIR": str(run_dir)})
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertNotIn("Active runtime state detected", res.plain)
        self.assertFalse(run_dir.exists())

    def test_uninstall_purge_removes_config(self):
        self._install_with_custom_config()
        res = self.run_script("uninstall.sh", "--purge")
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertFalse(self.target.exists())

    def test_uninstall_rejects_unknown_option(self):
        res = self.run_script("uninstall.sh", "--bogus")
        self.assertNotEqual(res.returncode, 0)

    @unittest.skipUnless(shutil.which("script"), "util-linux 'script' not available for a pseudo-TTY")
    def test_uninstall_interactive_prompt_defaults_to_keep_and_yes_deletes(self):
        cfg = self._install_with_custom_config()
        env = {
            "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.config),
            "TERM": "dumb",
        }
        cmd = f"bash {ROOT / 'uninstall.sh'}"
        # Empty answer (Enter) -> keep
        subprocess.run(["script", "-qec", cmd, "/dev/null"], input="\n", capture_output=True,
                       text=True, env=env, timeout=60)
        self.assertTrue(cfg.is_file(), "Pressing Enter at the prompt must keep config.toml")
        # Explicit yes -> delete
        subprocess.run(["script", "-qec", cmd, "/dev/null"], input="y\n", capture_output=True,
                       text=True, env=env, timeout=60)
        self.assertFalse(cfg.exists(), "Answering 'y' must delete config.toml")


if __name__ == "__main__":
    unittest.main(verbosity=2)
