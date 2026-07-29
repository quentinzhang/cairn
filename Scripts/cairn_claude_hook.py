#!/usr/bin/env python3
"""Publish a completed Claude Code turn to Cairn's local atomic inbox.

Claude Code invokes this script from its user-level Stop hook. Current Claude
Code versions provide ``last_assistant_message`` directly; transcript parsing
is retained only as a compatibility fallback and for the latest user prompt.
Turns without an extractable final answer are ignored: a Stop event alone is
not enough to create a user-facing note. Every failure is deliberately
isolated from Claude Code.
"""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cairn_payload import ensure_private_inbox, write_private_text


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Cairn"
INBOX = APP_SUPPORT / "inbox"

try:
    from cairn_locator import build_locator
except Exception:  # the locator is optional; hooks must never break without it
    def build_locator() -> dict[str, Any]:
        return {}

RESULT_LIMIT = 50_000


def read_hook_input() -> dict[str, Any]:
    try:
        parsed = json.load(sys.stdin)
        return parsed if isinstance(parsed, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def output_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    pieces: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") in {"text", "output_text"} and isinstance(block.get("text"), str):
            pieces.append(block["text"])
    return "\n".join(pieces).strip()


def message_from_record(record: dict[str, Any]) -> tuple[str, str]:
    nested = record.get("message")
    message = nested if isinstance(nested, dict) else record
    role = str(message.get("role") or record.get("type") or "")
    return role, output_text(message.get("content"))


def transcript_context(transcript_path: str | None) -> tuple[str, str | None]:
    """Return a fallback assistant result and the latest user prompt."""
    if not transcript_path:
        return "", None
    try:
        lines = Path(transcript_path).expanduser().read_text(encoding="utf-8").splitlines()
    except OSError:
        return "", None

    fallback_result = ""
    latest_user: str | None = None
    for raw in reversed(lines):
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        role, text = message_from_record(record)
        if role == "assistant" and text and not fallback_result:
            fallback_result = text
        elif role == "user" and text and latest_user is None:
            latest_user = text
        if fallback_result and latest_user:
            break
    return fallback_result, latest_user


def title_for(cwd: str) -> str:
    leaf = Path(cwd).name or cwd
    return f"Claude Code completed · {leaf or 'CLI'}"


def publish(payload: dict[str, Any]) -> None:
    ensure_private_inbox(INBOX)
    nonce = uuid.uuid4().hex
    temporary = INBOX / f".{nonce}.pending"
    destination = INBOX / (
        f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{nonce}.json"
    )
    write_private_text(temporary, json.dumps(payload, ensure_ascii=False))
    os.replace(temporary, destination)


def main() -> int:
    hook = read_hook_input()
    fallback_result, user_message = transcript_context(
        hook.get("transcript_path") if isinstance(hook.get("transcript_path"), str) else None
    )
    direct_result = hook.get("last_assistant_message")
    result = direct_result.strip() if isinstance(direct_result, str) else ""
    result = result or fallback_result
    if not result:
        return 0
    if len(result) > RESULT_LIMIT:
        result = result[:RESULT_LIMIT] + "\n\n… Result shortened by Cairn's Claude Code relay."

    session_id = str(hook.get("session_id") or "unknown-session")
    turn_id = str(hook.get("turn_id") or hook.get("prompt_id") or uuid.uuid4())
    cwd = str(hook.get("cwd") or "")
    payload: dict[str, Any] = {
        "id": f"{session_id}:{turn_id}",
        "version": 1,
        "event": "claude-code.turn.completed",
        "session_id": session_id,
        "turn_id": turn_id,
        "cwd": cwd,
        "title": title_for(cwd),
        "result": result,
        "status": "completed",
        "source": "claude-code",
        "platform": "cli",
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if user_message:
        payload["user_message"] = user_message
    locator = build_locator()
    if locator:
        payload["locator"] = locator
    model = hook.get("model")
    if isinstance(model, str) and model.strip():
        payload["model"] = model.strip()

    try:
        publish(payload)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
