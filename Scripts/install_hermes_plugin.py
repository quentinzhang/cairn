#!/usr/bin/env python3
"""Install Cairn's source-backed Hermes plugin and enable it safely."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from cairn_payload import payload_path


SOURCE = payload_path("HermesPlugin")
TARGET = Path.home() / ".hermes" / "plugins" / "cairn"


def install_link() -> None:
    if TARGET.is_symlink() and TARGET.resolve() == SOURCE.resolve():
        return
    if TARGET.exists() or TARGET.is_symlink():
        raise RuntimeError(f"Refusing to replace existing Hermes plugin: {TARGET}")
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(SOURCE, TARGET)


def relink() -> bool:
    """Point Hermes at *this* copy of the plugin, replacing a stale link.

    A symlink at ``~/.hermes/plugins/cairn`` is Cairn's own slot and nothing
    else's, so re-aiming it is safe — that is how a hook left behind by a
    deleted checkout gets repaired. A real directory is never touched: it may
    be someone's edited copy, and losing that silently would be unforgivable.
    """
    if TARGET.is_symlink():
        if TARGET.resolve() == SOURCE.resolve():
            return False
        TARGET.unlink()
    elif TARGET.exists():
        raise RuntimeError(f"Refusing to replace existing Hermes plugin: {TARGET}")
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(SOURCE, TARGET)
    return True


def unlink() -> bool:
    if TARGET.is_symlink():
        TARGET.unlink()
        return True
    if TARGET.exists():
        raise RuntimeError(f"Refusing to remove a real directory: {TARGET}")
    return False


def valid_source() -> bool:
    return (SOURCE / "plugin.yaml").is_file() and (SOURCE / "__init__.py").is_file()


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else "install"
    if action not in {"install", "uninstall"}:
        print("Usage: install_hermes_plugin.py [install|uninstall]", file=sys.stderr)
        return 2

    if action == "uninstall":
        try:
            subprocess.run(["hermes", "plugins", "disable", "cairn"], check=False)
            removed = unlink()
        except (OSError, RuntimeError) as error:
            print(f"Could not uninstall Cairn Hermes plugin: {error}", file=sys.stderr)
            return 1
        print(
            f"Cairn Hermes plugin removed: {TARGET}"
            if removed
            else f"Cairn Hermes plugin already absent: {TARGET}"
        )
        return 0

    if not valid_source():
        print(f"Invalid Cairn Hermes plugin source: {SOURCE}", file=sys.stderr)
        return 1
    try:
        install_link()
        subprocess.run(["hermes", "plugins", "enable", "cairn"], check=True)
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"Could not install Cairn Hermes plugin: {error}", file=sys.stderr)
        return 1
    print(f"Cairn Hermes plugin enabled: {TARGET} -> {SOURCE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
