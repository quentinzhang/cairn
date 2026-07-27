#!/usr/bin/env python3
"""Install or remove Cairn's Claude Code Stop hook without replacing others."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


SETTINGS_FILE = Path.home() / ".claude" / "settings.json"
SCRIPT = Path(__file__).with_name("cairn_claude_hook.py").resolve()
COMMAND = "/usr/bin/python3"
ARGS = [str(SCRIPT)]


def load() -> dict[str, Any]:
    if not SETTINGS_FILE.exists():
        return {}
    parsed = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("settings.json must contain a JSON object")
    return parsed


def write(config: dict[str, Any]) -> None:
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = SETTINGS_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, SETTINGS_FILE)


def is_cairn_handler(handler: Any) -> bool:
    if not isinstance(handler, dict):
        return False
    return handler.get("command") == COMMAND and handler.get("args") == ARGS


def install(config: dict[str, Any]) -> bool:
    hooks = config.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("settings.json has an invalid hooks field")
    stop = hooks.setdefault("Stop", [])
    if not isinstance(stop, list):
        raise ValueError("hooks.Stop must be an array")
    for group in stop:
        handlers = group.get("hooks", []) if isinstance(group, dict) else []
        if any(is_cairn_handler(handler) for handler in handlers):
            return False
    stop.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": COMMAND,
                    "args": ARGS,
                    "timeout": 3,
                    "statusMessage": "Sending completion to Cairn",
                }
            ]
        }
    )
    return True


def uninstall(config: dict[str, Any]) -> bool:
    hooks = config.get("hooks")
    if not isinstance(hooks, dict):
        return False
    stop = hooks.get("Stop")
    if not isinstance(stop, list):
        return False

    retained: list[Any] = []
    changed = False
    for group in stop:
        if not isinstance(group, dict):
            retained.append(group)
            continue
        handlers = group.get("hooks")
        if not isinstance(handlers, list):
            retained.append(group)
            continue
        kept = [handler for handler in handlers if not is_cairn_handler(handler)]
        changed = changed or len(kept) != len(handlers)
        if kept:
            updated = dict(group)
            updated["hooks"] = kept
            retained.append(updated)
    if retained:
        hooks["Stop"] = retained
    else:
        hooks.pop("Stop", None)
    if not hooks:
        config.pop("hooks", None)
    return changed


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else "install"
    if action not in {"install", "uninstall"}:
        print("Usage: install_claude_hook.py [install|uninstall]", file=sys.stderr)
        return 2
    try:
        config = load()
        changed = install(config) if action == "install" else uninstall(config)
        if changed:
            write(config)
            print(f"Cairn Claude Code hook {action}ed: {SETTINGS_FILE}")
        else:
            print(f"Cairn Claude Code hook already {action}ed: {SETTINGS_FILE}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Could not {action} Cairn Claude Code hook: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
