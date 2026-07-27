#!/usr/bin/env python3
"""Install or remove Cairn's Stop hook without disturbing other Codex hooks."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


HOOKS_FILE = Path.home() / ".codex" / "hooks.json"
SCRIPT = Path(__file__).with_name("cairn_codex_hook.py").resolve()
COMMAND = f'/usr/bin/python3 "{SCRIPT}"'


def load() -> dict[str, Any]:
    if not HOOKS_FILE.exists():
        return {"description": "Local Codex lifecycle hooks.", "hooks": {}}
    parsed = json.loads(HOOKS_FILE.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("hooks.json must contain a JSON object")
    parsed.setdefault("hooks", {})
    if not isinstance(parsed["hooks"], dict):
        raise ValueError("hooks.json has an invalid hooks field")
    return parsed


def write(config: dict[str, Any]) -> None:
    HOOKS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = HOOKS_FILE.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, HOOKS_FILE)


def install(config: dict[str, Any]) -> bool:
    stop = config["hooks"].setdefault("Stop", [])
    if not isinstance(stop, list):
        raise ValueError("hooks.Stop must be an array")
    for group in stop:
        for handler in group.get("hooks", []) if isinstance(group, dict) else []:
            if isinstance(handler, dict) and handler.get("command") == COMMAND:
                return False
    stop.append({
        "hooks": [{
            "type": "command",
            "command": COMMAND,
            "timeout": 3,
            "statusMessage": "Sending completion to Cairn",
        }]
    })
    return True


def uninstall(config: dict[str, Any]) -> bool:
    stop = config["hooks"].get("Stop", [])
    if not isinstance(stop, list):
        return False
    retained = []
    changed = False
    for group in stop:
        if not isinstance(group, dict):
            retained.append(group)
            continue
        handlers = group.get("hooks", [])
        kept = [handler for handler in handlers if not (isinstance(handler, dict) and handler.get("command") == COMMAND)]
        if len(kept) != len(handlers):
            changed = True
        if kept:
            group["hooks"] = kept
            retained.append(group)
    if retained:
        config["hooks"]["Stop"] = retained
    else:
        config["hooks"].pop("Stop", None)
    return changed


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else "install"
    if action not in {"install", "uninstall"}:
        print("Usage: install_codex_hook.py [install|uninstall]", file=sys.stderr)
        return 2
    try:
        config = load()
        changed = install(config) if action == "install" else uninstall(config)
        if changed:
            write(config)
            print(f"Cairn hook {action}ed: {HOOKS_FILE}")
        else:
            print(f"Cairn hook already {action}ed: {HOOKS_FILE}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Could not {action} Cairn hook: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
