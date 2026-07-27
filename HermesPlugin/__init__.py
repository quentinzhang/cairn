"""Cairn integration for Hermes Agent's turn-complete lifecycle hook.

Hermes calls ``post_llm_call`` only after an agent turn has a final assistant
response. This plugin persists a small event to Cairn's local inbox. It has no
network dependencies and every failure is deliberately isolated from Hermes.
"""

from __future__ import annotations

import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


INBOX = Path.home() / "Library" / "Application Support" / "Cairn" / "inbox"
RESULT_LIMIT = 50_000


def _build_locator() -> dict[str, Any]:
    """Record where this turn ran so Cairn can find its way back on click.

    Runs inside the Hermes process, so the environment and process ancestry
    seen here describe the hosting session (Terminal, iTerm2, Hermes Desktop).
    Failures degrade to an empty locator; they never reach Hermes.
    """
    locator: dict[str, Any] = {}
    for env_key, payload_key in {
        "TERM_PROGRAM": "term_program",
        "TERM_SESSION_ID": "term_session_id",
        "ITERM_SESSION_ID": "iterm_session_id",
        "TMUX_PANE": "tmux_pane",
    }.items():
        value = os.environ.get(env_key, "").strip()
        if value:
            locator[payload_key] = value
    try:
        locator["agent_pid"] = os.getpid()
        pid = os.getpid()
        tty = ""
        host_apps: list[dict[str, Any]] = []
        for _ in range(15):
            out = subprocess.run(
                ["/bin/ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
                capture_output=True, text=True, timeout=3, check=False,
            ).stdout.strip()
            if not out:
                break
            parts = out.split(None, 2)
            if len(parts) < 2:
                break
            ppid = int(parts[0])
            if not tty and parts[1] != "??":
                tty = parts[1]
            command = parts[2] if len(parts) > 2 else ""
            # Record every .app ancestor; the click-time resolver picks the
            # first layer that is a real, activatable GUI app.
            if "/Contents/MacOS/" in command:
                marker = command.find(".app/")
                if marker != -1 and ".framework/" not in command[: marker + 4]:
                    bundle = command[: marker + 4]
                    if all(entry["path"] != bundle for entry in host_apps):
                        host_apps.append({"path": bundle, "pid": pid})
            if ppid <= 1:
                break
            pid = ppid
        if host_apps:
            locator["host_app_path"] = host_apps[0]["path"]
            locator["host_app_pid"] = host_apps[0]["pid"]
            locator["host_apps"] = host_apps
        if tty:
            locator["tty"] = tty
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return locator


def _string(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _write_completion(payload: dict[str, Any]) -> None:
    """Atomically publish an event without propagating errors into Hermes."""
    try:
        INBOX.mkdir(parents=True, exist_ok=True)
        temporary = INBOX / f".{uuid.uuid4().hex}.pending"
        destination = INBOX / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{uuid.uuid4().hex}.json"
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, destination)
    except OSError:
        pass


def notify_cairn(
    session_id: str = "",
    turn_id: str = "",
    user_message: str = "",
    assistant_response: str = "",
    model: str = "",
    platform: str = "",
    **_: Any,
) -> None:
    """Register one successful Hermes completion with Cairn's local inbox."""
    result = _string(assistant_response)
    if not result:
        return
    if len(result) > RESULT_LIMIT:
        result = result[:RESULT_LIMIT] + "\n\n… Result shortened by Cairn's Hermes relay."

    session = _string(session_id) or "unknown-session"
    turn = _string(turn_id) or uuid.uuid4().hex
    surface = _string(platform) or "hermes"
    payload = {
        "id": f"hermes:{session}:{turn}",
        "version": 1,
        "event": "hermes.turn.completed",
        "session_id": session,
        "turn_id": turn,
        "cwd": os.getcwd(),
        "title": f"Hermes completed · {surface}",
        "result": result,
        "status": "completed",
        "source": "hermes",
        "user_message": _string(user_message),
        "model": _string(model),
        "platform": surface,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    locator = _build_locator()
    if locator:
        payload["locator"] = locator
    _write_completion(payload)


def register(ctx: Any) -> None:
    ctx.register_hook("post_llm_call", notify_cairn)
