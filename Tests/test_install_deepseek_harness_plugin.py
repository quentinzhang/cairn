#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "Scripts"))

import install_deepseek_harness_plugin as plugin  # noqa: E402
import cairn_connect  # noqa: E402


class DeepSeekHarnessInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="cairn-dsh-installer-"))
        self.home = self.root / "dsh-home"
        self.home.mkdir()
        self.support = self.root / "Application Support" / "Cairn"
        self.source = self.root / "source"
        shutil.copytree(REPO / "DeepSeekHarnessPlugin", self.source)

        self.patchers = [
            mock.patch.object(plugin, "CAIRN_SUPPORT", self.support),
            mock.patch.object(plugin, "STABLE_BUNDLE", self.support / "DeepSeekHarnessPlugin"),
            mock.patch.object(plugin, "SELECTION_FILE", self.support / "deepseek-harness.json"),
            mock.patch.object(plugin, "SOURCE", self.source),
            mock.patch.object(plugin, "_selected_home", None),
        ]
        for patcher in self.patchers:
            patcher.start()

    def tearDown(self) -> None:
        for patcher in reversed(self.patchers):
            patcher.stop()
        shutil.rmtree(self.root, ignore_errors=True)

    def profile_manifest(self, bundles=None, dependencies=None) -> Path:
        directory = plugin.profile_dir(self.home)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "package.json"
        path.write_text(
            json.dumps(
                {
                    "name": "dsh-profile-web",
                    "private": True,
                    "dependencies": dependencies or {},
                    "dsh": {
                        "profile": {
                            "bundles": bundles
                            if bundles is not None
                            else ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
                        }
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return path

    def cli(self, version="0.1.0-rc.6"):
        return {"kind": "global", "command": ["/test/dsh"], "version": version}

    def install_in_manifest(self) -> None:
        path = plugin.profile_dir(self.home) / "package.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["dependencies"][plugin.PLUGIN_NAME] = "link:%s" % plugin.STABLE_BUNDLE
        if plugin.PLUGIN_NAME not in value["dsh"]["profile"]["bundles"]:
            value["dsh"]["profile"]["bundles"].append(plugin.PLUGIN_NAME)
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def remove_from_manifest(self) -> None:
        path = plugin.profile_dir(self.home) / "package.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["dependencies"].pop(plugin.PLUGIN_NAME, None)
        value["dsh"]["profile"]["bundles"] = [
            item
            for item in value["dsh"]["profile"]["bundles"]
            if item != plugin.PLUGIN_NAME
        ]
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def test_explicit_custom_home_is_validated_and_saved(self) -> None:
        selected = plugin.select_dsh_home(self.home, persist=True)
        self.assertEqual(selected, self.home.resolve())
        self.assertEqual(plugin.selected_dsh_home(), self.home.resolve())
        self.assertEqual(
            json.loads(plugin.SELECTION_FILE.read_text(encoding="utf-8"))["dsh_home"],
            str(self.home.resolve()),
        )
        self.assertEqual(plugin.SELECTION_FILE.stat().st_mode & 0o777, 0o600)
        with self.assertRaisesRegex(plugin.InstallerError, "absolute"):
            plugin.select_dsh_home(Path("relative"))

    def test_consent_refusal_does_not_persist_or_install(self) -> None:
        status = {
            "id": "deepseek-harness",
            "state": "available",
            "issue": None,
            "message": None,
            "consent": True,
            "follow_up": None,
        }
        with mock.patch.object(
            sys,
            "argv",
            [
                "cairn_connect.py",
                "connect",
                "deepseek-harness",
                "--dsh-home",
                str(self.home),
            ],
        ), mock.patch.object(
            cairn_connect.install_deepseek_harness_plugin,
            "select_dsh_home",
        ) as select_home, mock.patch.object(
            cairn_connect.install_deepseek_harness_plugin,
            "install",
        ) as install, mock.patch.object(
            cairn_connect,
            "deepseek_harness_status",
            return_value=status,
        ), redirect_stdout(StringIO()):
            self.assertEqual(cairn_connect.main(), 1)
        select_home.assert_called_once_with(self.home, persist=False)
        install.assert_not_called()

    def test_running_source_checkout_fallback_uses_no_process_environment(self) -> None:
        checkout = self.root / "deepseek-harness"
        (checkout / "apps" / "cli").mkdir(parents=True)
        (checkout / "package.json").write_text(
            json.dumps({"name": "@deepseek-ai/dsh-root"}), encoding="utf-8"
        )
        (checkout / "apps" / "cli" / "package.json").write_text(
            json.dumps({"name": "@deepseek-ai/dsh", "version": "0.1.0-rc.5"}),
            encoding="utf-8",
        )
        (checkout / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n", encoding="utf-8")

        with mock.patch.object(
            plugin, "_process_rows", return_value=[(42, "node /x/pnpm dsh web")]
        ), mock.patch.object(plugin, "_process_cwd", return_value=checkout), mock.patch.object(
            plugin.shutil,
            "which",
            side_effect=lambda name: "/test/pnpm" if name == "pnpm" else None,
        ):
            discovered = plugin.discover_cli()
        self.assertEqual(discovered["kind"], "source")
        self.assertEqual(discovered["version"], "0.1.0-rc.5")
        self.assertEqual(
            discovered["command"], ["/test/pnpm", "--dir", str(checkout.resolve()), "dsh"]
        )

    def test_status_uses_profile_and_live_marker_as_separate_facts(self) -> None:
        self.profile_manifest()
        with mock.patch.object(plugin, "discover_cli", return_value=self.cli()):
            self.assertEqual(plugin.status(self.home)["state"], "available")

            self.install_in_manifest()
            connected_on_restart = plugin.status(self.home)
            self.assertEqual(connected_on_restart["state"], "restart_to_connect")
            self.assertEqual(
                connected_on_restart["follow_up"], "deepseek_harness_restart"
            )

            path = plugin.marker_path(self.home)
            path.parent.mkdir(parents=True)
            path.write_text(
                json.dumps(
                    {
                        "plugin": plugin.PLUGIN_NAME,
                        "plugin_version": plugin.PLUGIN_VERSION,
                        "dsh_version": "0.1.0-rc.6",
                        "pid": os.getpid(),
                        "port": 43123,
                        "owner": "test-owner",
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(plugin.status(self.home)["state"], "connected")
            self.remove_from_manifest()
            disconnect_on_restart = plugin.status(self.home)
            self.assertEqual(disconnect_on_restart["state"], "restart_to_disconnect")
            self.assertEqual(disconnect_on_restart["port"], 43123)

    def test_unknown_version_and_missing_cli_never_look_connected(self) -> None:
        self.profile_manifest()
        self.install_in_manifest()
        with mock.patch.object(
            plugin, "discover_cli", return_value=self.cli("0.1.0-rc.99")
        ):
            status = plugin.status(self.home)
            self.assertEqual((status["state"], status["issue"]), ("attention", "unsupported_version"))
        with mock.patch.object(plugin, "discover_cli", return_value=None):
            status = plugin.status(self.home)
            self.assertEqual((status["state"], status["issue"]), ("attention", "cli_missing"))

    def test_connect_disconnect_and_repeats_are_idempotent(self) -> None:
        self.profile_manifest()
        calls = []

        def run(command, **_kwargs):
            calls.append(command)
            if "add" in command:
                self.install_in_manifest()
            elif "remove" in command:
                self.remove_from_manifest()
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(plugin, "discover_cli", return_value=self.cli()), mock.patch.object(
            plugin.subprocess, "run", side_effect=run
        ):
            first = plugin.install(self.home)
            second = plugin.install(self.home)
            self.assertEqual(first["state"], "restart_to_connect")
            self.assertEqual(second["state"], "restart_to_connect")
            self.assertEqual(sum("add" in call for call in calls), 1)
            self.assertEqual(
                json.loads((plugin.STABLE_BUNDLE / "package.json").read_text())["name"],
                plugin.PLUGIN_NAME,
            )
            self.assertFalse((plugin.STABLE_BUNDLE / "index.test.js").exists())

            plugin.uninstall(self.home)
            plugin.uninstall(self.home)
            self.assertEqual(sum("remove" in call for call in calls), 1)

    def test_cli_failure_restores_manifest_and_never_replaces_foreign_bundle(self) -> None:
        manifest = self.profile_manifest()
        original = manifest.read_bytes()

        def failing_run(command, **_kwargs):
            self.install_in_manifest()
            return subprocess.CompletedProcess(command, 1, "", "pnpm failed")

        with mock.patch.object(plugin, "discover_cli", return_value=self.cli()), mock.patch.object(
            plugin.subprocess, "run", side_effect=failing_run
        ):
            with self.assertRaisesRegex(plugin.InstallerError, "pnpm failed"):
                plugin.install(self.home)
        self.assertEqual(manifest.read_bytes(), original)

        other = self.root / "other-plugin"
        other.mkdir()
        self.profile_manifest(
            bundles=["@deepseek-ai/dsh-base", plugin.PLUGIN_NAME],
            dependencies={plugin.PLUGIN_NAME: "link:%s" % other},
        )
        with mock.patch.object(plugin, "discover_cli", return_value=self.cli()), mock.patch.object(
            plugin.subprocess, "run"
        ) as run_mock:
            with self.assertRaisesRegex(plugin.InstallerError, "external bundle"):
                plugin.install(self.home)
            run_mock.assert_not_called()

    def test_damaged_profile_is_attention_and_not_modified(self) -> None:
        directory = plugin.profile_dir(self.home)
        directory.mkdir(parents=True)
        manifest = directory / "package.json"
        manifest.write_text("{ broken", encoding="utf-8")
        before = manifest.read_bytes()
        with mock.patch.object(plugin, "discover_cli", return_value=self.cli()):
            status = plugin.status(self.home)
            self.assertEqual((status["state"], status["issue"]), ("attention", "config_invalid"))
            with self.assertRaises(plugin.InstallerError):
                plugin.install(self.home)
        self.assertEqual(manifest.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
