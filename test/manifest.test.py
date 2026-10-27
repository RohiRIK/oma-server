#!/usr/bin/env python3
"""Manifest, packaging, and Panel.qml contract checks for rohirik.oma-server."""
import json
import os
import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_manifest():
    with open(ROOT / "manifest.json", encoding="utf-8") as fh:
        return json.load(fh)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.m = load_manifest()

    def test_schema_version_is_1(self):
        self.assertEqual(self.m["schemaVersion"], 1)

    def test_id_matches_plugin_identifier(self):
        self.assertEqual(self.m["id"], "rohirik.oma-server")

    def test_declares_bar_widget_kind(self):
        self.assertIn("bar-widget", self.m["kinds"])

    def test_entry_point_file_exists(self):
        entry = self.m["entryPoints"]["barWidget"]
        self.assertEqual(entry, "Panel.qml")
        self.assertTrue((ROOT / entry).is_file(), f"entry point {entry} is missing")
        self.assertFalse((ROOT / "BarWidget.qml").exists(), "deprecated BarWidget.qml must not exist")

    def test_bar_widget_metadata_is_present(self):
        bw = self.m["barWidget"]
        for field in ("displayName", "description", "category", "defaultSection"):
            self.assertIn(field, bw)
        self.assertIn(bw["defaultSection"], ("left", "center", "right"))
        self.assertFalse(bw["allowMultiple"])

    def test_required_repository_files_exist(self):
        required = (
            "Panel.qml",
            "README.md",
            "LICENSE",
            "preview.png",
            "install.sh",
            "uninstall.sh",
            "bin/oma-server",
            "bin/omarchy-server-mode",
            "lib/ui.sh",
            "lib/config.sh",
            "lib/snapshot.sh",
            "lib/transition.sh",
            "lib/deep.sh",
            "libexec/oma-server-deep-helper",
            "libexec/oma-server-deep-shell",
            "templates/sudoers-oma-server-deep",
            "config/config.toml",
            "hooks/post-boot.d/99-server-profile-check.sh",
        )
        for rel in required:
            p = ROOT / rel
            self.assertTrue(p.is_file(), f"{rel} is missing")


class PackagingAndQmlContractTests(unittest.TestCase):
    def test_no_symlinks_inside_plugin_tree(self):
        for p in ROOT.rglob("*"):
            if ".git" in p.parts:
                continue
            self.assertFalse(p.is_symlink(), f"Symlink not permitted in plugin tree: {p}")

    def test_cli_binaries_are_regular_executables_and_in_sync(self):
        oma = ROOT / "bin/oma-server"
        alias = ROOT / "bin/omarchy-server-mode"
        self.assertTrue(os.access(oma, os.X_OK), "bin/oma-server must be executable")
        self.assertTrue(os.access(alias, os.X_OK), "bin/omarchy-server-mode must be executable")
        self.assertEqual(oma.read_text(encoding="utf-8"), alias.read_text(encoding="utf-8"))

    def test_bash_syntax_valid_across_all_scripts(self):
        scripts = [
            ROOT / "install.sh",
            ROOT / "uninstall.sh",
            ROOT / "bin/oma-server",
            ROOT / "bin/omarchy-server-mode",
            ROOT / "hooks/post-boot.d/99-server-profile-check.sh",
            ROOT / "libexec/oma-server-deep-helper",
            ROOT / "libexec/oma-server-deep-shell",
            *sorted((ROOT / "lib").glob("*.sh")),
        ]
        for script in scripts:
            p = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, f"bash -n failed for {script}:\n{p.stderr}")

    def test_panel_qml_contract_and_theme_compliance(self):
        qml = (ROOT / "Panel.qml").read_text(encoding="utf-8")
        self.assertNotIn(
            "import QtQuick.Controls",
            qml,
            "Panel.qml must not import QtQuick.Controls alongside qs.Ui (Button collision)",
        )
        self.assertIn('moduleName: "rohirik.oma-server"', qml)
        self.assertIn('ipcTarget: "rohirik.oma-server"', qml)
        self.assertIn("function prepareHomelabFreeze()", qml)
        self.assertIn("component LaptopScreenIcon: Item", qml)
        self.assertIn("lit: !root.isHomelabMode", qml)
        hex_literals = re.findall(r"#[0-9a-fA-F]{3,8}\b", qml)
        self.assertEqual(hex_literals, [], f"Hardcoded hex colors found in Panel.qml: {hex_literals}")

    def test_zero_emoji_policy(self):
        emoji_re = re.compile(
            "["
            "\U0001F300-\U0001F9FF"
            "\U0001FA00-\U0001FAFF"
            "\U00002600-\U000026FF"
            "\U00002700-\U000027BF"
            "]+",
            flags=re.UNICODE,
        )
        for p in sorted(ROOT.rglob("*")):
            if ".git" in p.parts or not p.is_file() or p.suffix in {".png", ".jpg", ".webp"}:
                continue
            if p.resolve() == pathlib.Path(__file__).resolve():
                continue
            txt = p.read_text(encoding="utf-8")
            matches = emoji_re.findall(txt)
            self.assertEqual(matches, [], f"Emoji found in {p.relative_to(ROOT)}: {matches}")

    def test_omarchy_plugin_validate_passes(self):
        if shutil.which("omarchy") is None:
            self.skipTest("Omarchy is not installed")
        p = subprocess.run(
            ["omarchy", "plugin", "validate", str(ROOT)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            p.returncode,
            0,
            "omarchy plugin validate failed:\n" + p.stdout + p.stderr,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
