#!/usr/bin/env python3
"""Find Cairn's payload directories from either layout Cairn ships in.

Cairn exists on disk in two shapes, and every installer has to work in both:

    a checkout            Scripts/install_hermes_plugin.py, HermesPlugin/
    an installed app      Cairn.app/Contents/Resources/install_hermes_plugin.py,
                          Cairn.app/Contents/Resources/HermesPlugin/

The bridge scripts are siblings of the installers in both shapes, so those
resolve with ``Path(__file__).with_name(...)``. The payload *directories* do
not: in a checkout they sit one level up, in the bundle they sit right here.
Hard-coding either one is what made a downloaded app unable to connect
anything without a source checkout beside it.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import TextIO

SCRIPT_DIR = Path(__file__).resolve().parent
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600


def payload_path(name: str) -> Path:
    """Return the bundled payload directory ``name``, whichever layout we are in.

    Prefers the sibling (installed app) over the parent (checkout), so a copy
    of Cairn running from /Applications never reaches sideways into whatever
    checkout happens to be on disk. Returns the checkout location when neither
    exists, so callers report a missing payload against the developer path.
    """
    for base in (SCRIPT_DIR, SCRIPT_DIR.parent):
        candidate = base / name
        if candidate.exists():
            return candidate
    return SCRIPT_DIR.parent / name


def ensure_private_inbox(inbox: Path) -> None:
    """Create or repair Cairn's support and inbox directories for this user."""
    support = inbox.parent
    support.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    os.chmod(support, PRIVATE_DIRECTORY_MODE)
    inbox.mkdir(exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    os.chmod(inbox, PRIVATE_DIRECTORY_MODE)


def write_private_text(path: Path, text: str) -> None:
    """Create a new private UTF-8 file without exposing a partial payload."""
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        PRIVATE_FILE_MODE,
    )
    stream: TextIO | None = None
    try:
        stream = os.fdopen(descriptor, "w", encoding="utf-8")
        descriptor = -1
        stream.write(text)
        stream.close()
        stream = None
        os.chmod(path, PRIVATE_FILE_MODE)
    except BaseException:
        if stream is not None:
            stream.close()
        elif descriptor >= 0:
            os.close(descriptor)
        try:
            path.unlink()
        except OSError:
            pass
        raise
