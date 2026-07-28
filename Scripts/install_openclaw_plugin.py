#!/usr/bin/env python3
"""Install Cairn's source-backed OpenClaw agent_end plugin safely."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Optional

from cairn_payload import payload_path


PLUGIN_ID = "cairn"
SOURCE = payload_path("OpenClawPlugin")
CONFIG_FILE = Path(
    os.environ.get("OPENCLAW_CONFIG_PATH", Path.home() / ".openclaw" / "openclaw.json")
).expanduser()


def candidate_node_bins() -> list[Path | None]:
    candidates: list[Path | None] = [None]
    nvm_root = Path.home() / ".nvm" / "versions" / "node"
    if nvm_root.is_dir():
        candidates.extend(
            sorted(
                (path / "bin" for path in nvm_root.iterdir() if (path / "bin" / "node").is_file()),
                reverse=True,
            )
        )
    return candidates


def openclaw_environment() -> tuple[str, dict[str, str]]:
    executable = shutil.which("openclaw")
    if not executable:
        raise RuntimeError("openclaw is not installed or is not on PATH")
    for node_bin in candidate_node_bins():
        environment = os.environ.copy()
        if node_bin is not None:
            environment["PATH"] = f"{node_bin}{os.pathsep}{environment.get('PATH', '')}"
        probe = subprocess.run(
            [executable, "--version"],
            env=environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if probe.returncode == 0:
            return executable, environment
    raise RuntimeError("OpenClaw needs a supported Node.js runtime (22.22+ or 24.15+)")


def run_cli(executable: str, environment: dict[str, str], *arguments: str) -> None:
    subprocess.run([executable, *arguments], env=environment, check=True)


def load_config() -> dict[str, Any]:
    if not CONFIG_FILE.exists():
        return {}
    parsed = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("openclaw.json must contain a JSON object")
    return parsed


def supports_conversation_access(
    executable: str, environment: dict[str, str]
) -> bool:
    """Probe the live CLI schema because some OpenClaw builds predate this policy."""
    with tempfile.TemporaryDirectory(prefix="cairn-openclaw-schema-") as directory:
        config_path = Path(directory) / "openclaw.json"
        config_path.write_text(
            json.dumps(
                {
                    "plugins": {
                        "entries": {
                            PLUGIN_ID: {
                                "hooks": {"allowConversationAccess": True}
                            }
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        probe_environment = environment.copy()
        probe_environment["OPENCLAW_CONFIG_PATH"] = str(config_path)
        result = subprocess.run(
            [
                executable,
                "config",
                "get",
                f"plugins.entries.{PLUGIN_ID}.hooks.allowConversationAccess",
            ],
            env=probe_environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return result.returncode == 0


def configure_plugin_entry(
    config: dict[str, Any], *, allow_conversation_access: bool
) -> bool:
    plugins = config.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        raise ValueError("openclaw.json has an invalid plugins field")
    entries = plugins.setdefault("entries", {})
    if not isinstance(entries, dict):
        raise ValueError("plugins.entries must be an object")
    entry = entries.setdefault(PLUGIN_ID, {})
    if not isinstance(entry, dict):
        raise ValueError(f"plugins.entries.{PLUGIN_ID} must be an object")
    changed = entry.get("enabled") is not True
    entry["enabled"] = True
    hooks = entry.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"plugins.entries.{PLUGIN_ID}.hooks must be an object")
    if allow_conversation_access:
        changed = changed or hooks.get("allowConversationAccess") is not True
        hooks["allowConversationAccess"] = True
    elif "allowConversationAccess" in hooks:
        hooks.pop("allowConversationAccess")
        changed = True
    if not hooks:
        entry.pop("hooks", None)
    return changed


def conversation_access_enabled(config: dict[str, Any]) -> bool:
    plugins = config.get("plugins")
    entries = plugins.get("entries") if isinstance(plugins, dict) else None
    entry = entries.get(PLUGIN_ID) if isinstance(entries, dict) else None
    hooks = entry.get("hooks") if isinstance(entry, dict) else None
    return isinstance(hooks, dict) and hooks.get("allowConversationAccess") is True


def write_config(config: dict[str, Any]) -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = CONFIG_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, CONFIG_FILE)


def is_linked_to_source(config: dict[str, Any]) -> bool:
    plugins = config.get("plugins")
    if not isinstance(plugins, dict):
        return False
    installs = plugins.get("installs")
    install = installs.get(PLUGIN_ID) if isinstance(installs, dict) else None
    if isinstance(install, dict):
        for key in ("sourcePath", "installPath"):
            value = install.get(key)
            if isinstance(value, str) and Path(value).expanduser().resolve() == SOURCE.resolve():
                return True
    load = plugins.get("load")
    paths = load.get("paths") if isinstance(load, dict) else None
    return isinstance(paths, list) and any(
        isinstance(value, str) and Path(value).expanduser().resolve() == SOURCE.resolve()
        for value in paths
    )


def plugin_id_at(path: Path) -> Optional[str]:
    try:
        manifest = json.loads((path / "openclaw.plugin.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    plugin_id = manifest.get("id") if isinstance(manifest, dict) else None
    return plugin_id if isinstance(plugin_id, str) else None


def prefer_current_plugin_source(config: dict[str, Any]) -> bool:
    """Keep one explicit load path for Cairn, with this installer source first."""
    plugins = config.setdefault("plugins", {})
    if not isinstance(plugins, dict):
        raise ValueError("openclaw.json has an invalid plugins field")
    load = plugins.setdefault("load", {})
    if not isinstance(load, dict):
        raise ValueError("plugins.load must be an object")
    paths = load.setdefault("paths", [])
    if not isinstance(paths, list):
        raise ValueError("plugins.load.paths must be an array")

    source_path = str(SOURCE.resolve())
    retained: list[str] = []
    for value in paths:
        if not isinstance(value, str):
            continue
        candidate = Path(value).expanduser()
        if candidate.resolve() == SOURCE.resolve():
            continue
        # A load path that no longer exists makes the entire config invalid,
        # and OpenClaw then refuses every plugins command — including the one
        # that would fix it. Dropping it is the repair, not a loss: there is
        # nothing at the other end to lose.
        if not candidate.exists():
            continue
        if plugin_id_at(candidate) == PLUGIN_ID:
            continue
        retained.append(value)
    normalized = [source_path, *retained]
    if normalized == paths:
        return False
    load["paths"] = normalized
    return True


def install(
    executable: str,
    environment: dict[str, str],
    *,
    raw_access_supported: bool,
) -> None:
    config = load_config()
    if configure_plugin_entry(
        config, allow_conversation_access=raw_access_supported
    ):
        write_config(config)
    if not is_linked_to_source(config):
        # OpenClaw requires an explicit trust acknowledgement for local,
        # non-ClawHub sources. Cairn's installer is itself shipped alongside
        # this reviewed source directory, so make that acknowledgement
        # non-interactively while retaining the official plugin CLI path.
        run_cli(
            executable,
            environment,
            "plugins",
            "install",
            "--link",
            "--force",
            str(SOURCE),
        )
    config = load_config()
    if prefer_current_plugin_source(config):
        write_config(config)
    run_cli(executable, environment, "plugins", "enable", PLUGIN_ID)
    config = load_config()
    if configure_plugin_entry(
        config, allow_conversation_access=raw_access_supported
    ):
        write_config(config)
    print(f"Cairn OpenClaw plugin enabled from: {SOURCE}")
    if raw_access_supported:
        print("OpenClaw conversation-hook access enabled for Cairn.")


def uninstall(executable: str, environment: dict[str, str]) -> None:
    run_cli(executable, environment, "plugins", "uninstall", "--force", PLUGIN_ID)
    print("Cairn OpenClaw plugin uninstalled.")


def restart_gateway(executable: str, environment: dict[str, str]) -> None:
    result = subprocess.run(
        [executable, "gateway", "restart"],
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if result.returncode == 0:
        print("OpenClaw Gateway restarted.")
    else:
        print("Restart the OpenClaw Gateway or Desktop client to load Cairn.", file=sys.stderr)


def confirmation(prompt: str, *, default: bool) -> bool:
    if not sys.stdin.isatty():
        return False
    suffix = " [Y/n] " if default else " [y/N] "
    answer = input(prompt + suffix).strip().lower()
    if not answer:
        return default
    return answer in {"y", "yes"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Connect OpenClaw to Cairn")
    parser.add_argument("action", nargs="?", choices=("install", "uninstall"), default="install")
    parser.add_argument(
        "--allow-conversation-access",
        action="store_true",
        help="allow Cairn to read the final OpenClaw conversation",
    )
    parser.add_argument(
        "--restart-gateway",
        action="store_true",
        help="restart the managed OpenClaw Gateway after the change",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not (SOURCE / "openclaw.plugin.json").is_file() or not (SOURCE / "index.js").is_file():
        print(f"Invalid Cairn OpenClaw plugin source: {SOURCE}", file=sys.stderr)
        return 1
    try:
        executable, environment = openclaw_environment()
        if args.action == "install":
            raw_access_supported = supports_conversation_access(executable, environment)
            already_allowed = conversation_access_enabled(load_config())
            allowed = already_allowed or args.allow_conversation_access
            if raw_access_supported and not allowed:
                allowed = confirmation(
                    "Cairn saves the last prompt and final reply. Allow conversation access?",
                    default=False,
                )
            if raw_access_supported and not allowed:
                if not sys.stdin.isatty():
                    print(
                        "Conversation access is required. Re-run with "
                        "--allow-conversation-access.",
                        file=sys.stderr,
                    )
                    return 2
                print("OpenClaw connection skipped.")
                return 0
            install(
                executable,
                environment,
                raw_access_supported=raw_access_supported,
            )
        else:
            uninstall(executable, environment)

        should_restart = args.restart_gateway or confirmation(
            "Restart OpenClaw Gateway now?",
            default=True,
        )
        if should_restart:
            restart_gateway(executable, environment)
        else:
            print("Restart OpenClaw Gateway to apply the change.")
        return 0
    except (
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        RuntimeError,
    ) as error:
        print(f"Could not {args.action} Cairn OpenClaw plugin: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
