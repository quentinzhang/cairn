#!/usr/bin/env python3
"""Install Cairn's source-backed Hermes plugin and enable it safely."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


SOURCE = Path(__file__).resolve().parent.parent / "HermesPlugin"
TARGET = Path.home() / ".hermes" / "plugins" / "cairn"


def install_link() -> None:
    if TARGET.is_symlink() and TARGET.resolve() == SOURCE.resolve():
        return
    if TARGET.exists() or TARGET.is_symlink():
        raise RuntimeError(f"Refusing to replace existing Hermes plugin: {TARGET}")
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(SOURCE, TARGET)


def main() -> int:
    if not (SOURCE / "plugin.yaml").is_file() or not (SOURCE / "__init__.py").is_file():
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
