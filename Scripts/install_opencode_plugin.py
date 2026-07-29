#!/usr/bin/env python3
"""Install Cairn's source-backed OpenCode plugin without editing user config."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cairn_payload import payload_path


SOURCE = payload_path("OpenCodePlugin") / "index.js"
TARGET = Path.home() / ".config" / "opencode" / "plugins" / "cairn.js"


def valid_source() -> bool:
    return SOURCE.is_file()


def relink() -> bool:
    """Point Cairn's reserved plugin slot at this app copy.

    Only a symlink is Cairn-owned and safe to repair. A real file or directory
    may be a user's plugin, so it is never replaced or removed.
    """
    if TARGET.is_symlink():
        if TARGET.resolve() == SOURCE.resolve():
            return False
        TARGET.unlink()
    elif TARGET.exists():
        raise RuntimeError(f"Refusing to replace existing OpenCode plugin: {TARGET}")
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(SOURCE, TARGET)
    return True


def unlink() -> bool:
    if TARGET.is_symlink():
        TARGET.unlink()
        return True
    if TARGET.exists():
        raise RuntimeError(f"Refusing to remove a real OpenCode plugin: {TARGET}")
    return False


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else "install"
    if action not in {"install", "uninstall"}:
        print("Usage: install_opencode_plugin.py [install|uninstall]", file=sys.stderr)
        return 2
    try:
        if action == "uninstall":
            removed = unlink()
            print("Cairn OpenCode plugin removed" if removed else "Cairn OpenCode plugin already absent")
            return 0
        if not valid_source():
            raise RuntimeError(f"Invalid Cairn OpenCode plugin source: {SOURCE}")
        relink()
        print(f"Cairn OpenCode plugin linked: {TARGET} -> {SOURCE}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"Could not install Cairn OpenCode plugin: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
