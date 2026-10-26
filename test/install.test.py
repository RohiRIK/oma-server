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
exit 0
""")
        write_executable(self.bin_dir / "omarchy-shell", f"""#!/usr/bin/env bash
echo "omarchy-shell $*" >> "{log}"
exit 0
""")
        write_executable(self.bin_dir / "omarchy", f"""#!/usr/bin/env bash
echo "omarchy $*" >> "{log}"
if [[ "$1 $2" == "plugin enable" && "${{OMA_TEST_ENABLE_FAIL:-0}}" == "1" ]]; then
    echo "error: omarchy-shell IPC timed out" >&2
    exit 1
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

    def test_install_in_graphical_session_restarts_shell(self):
        res = self.run_script("install.sh", extra_env={"OMA_TEST_SHELL_RUNNING": "1"}, graphical=True)
        self.assertEqual(res.returncode, 0, res.plain)
        self.assertIn("restart-shell", self.calls())

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
