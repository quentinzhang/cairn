#!/usr/bin/env python3
"""Capture where an agent turn ran, so Cairn can find its way back later.

A Cairn hook executes *inside* the agent's process tree, at the moment the
turn completes. That is the only moment the trail is visible: the terminal
session identifiers are in the environment, and the process ancestry leads
straight up to whichever GUI app hosts the session (Terminal, iTerm2,
VS Code, a desktop client). This module records those clues as a small
``locator`` dict; the Cairn app replays them when a note is clicked.

Never raises: on any failure it degrades to whatever it did manage to see.
"""

from __future__ import annotations

import os
import subprocess
from typing import Any

_ENV_KEYS = {
    "TERM_PROGRAM": "term_program",
    "TERM_SESSION_ID": "term_session_id",
    "ITERM_SESSION_ID": "iterm_session_id",
    "TMUX_PANE": "tmux_pane",
    "WEZTERM_PANE": "wezterm_pane",
    "KITTY_WINDOW_ID": "kitty_window_id",
}

_MAX_ANCESTRY_DEPTH = 15


def _ps(pid: int) -> tuple[int, str, str] | None:
    """Return (ppid, tty, command) for a pid, or None."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        ).stdout.strip()
        if not out:
            return None
        parts = out.split(None, 2)
        if len(parts) < 2:
            return None
        ppid = int(parts[0])
        tty = parts[1]
        command = parts[2] if len(parts) > 2 else ""
        return ppid, tty, command
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def build_locator() -> dict[str, Any]:
    locator: dict[str, Any] = {}

    for env_key, payload_key in _ENV_KEYS.items():
        value = os.environ.get(env_key, "").strip()
        if value:
            locator[payload_key] = value

    try:
        locator["agent_pid"] = os.getppid()
    except OSError:
        pass

    # Walk toward launchd, recording EVERY ancestor whose executable lives in
    # an .app bundle, innermost first. Some hosts stack bundles — Claude Code
    # runs as a headless harness bundle underneath the Claude desktop app —
    # and only the resolver at click time can tell which layer is a real,
    # activatable GUI app. Cut paths at the FIRST ".app/" boundary so Electron
    # helper bundles resolve to their outer application. Two exclusions: the
    # hook's own process (its interpreter can live inside Xcode.app or
    # Python.app — never a window anyone can return to), and
    # framework-internal pseudo-apps.
    pid = os.getpid()
    tty = ""
    is_self = True
    host_apps: list[dict[str, Any]] = []
    for _ in range(_MAX_ANCESTRY_DEPTH):
        info = _ps(pid)
        if info is None:
            break
        ppid, proc_tty, command = info
        if not tty and proc_tty and proc_tty != "??":
            tty = proc_tty
        if not is_self and "/Contents/MacOS/" in command:
            marker = command.find(".app/")
            if marker != -1 and ".framework/" not in command[: marker + 4]:
                bundle = command[: marker + 4]
                if all(entry["path"] != bundle for entry in host_apps):
                    host_apps.append({"path": bundle, "pid": pid})
        is_self = False
        if ppid <= 1:
            break
        pid = ppid

    if host_apps:
        locator["host_app_path"] = host_apps[0]["path"]
        locator["host_app_pid"] = host_apps[0]["pid"]
        locator["host_apps"] = host_apps
    if tty:
        locator["tty"] = tty
    return locator
