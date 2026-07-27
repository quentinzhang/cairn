#!/usr/bin/env python3
"""Forward the latest completed Codex result to a locally running Cairn app.

Codex invokes this script from a Stop hook and passes hook metadata as JSON on
stdin. The only intentionally undocumented dependency is transcript parsing;
the extractor accepts both response_item messages and event_msg fallbacks.
"""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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
        return content
    if not isinstance(content, list):
        return ""
    pieces: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") in {"output_text", "text"} and isinstance(block.get("text"), str):
            pieces.append(block["text"])
    return "\n".join(pieces).strip()


def latest_completion(transcript_path: str | None) -> tuple[str, str | None]:
    """Return the final assistant message and its turn id from a Codex JSONL transcript."""
    if not transcript_path:
        return "Codex completed this turn.", None
    try:
        lines = Path(transcript_path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return "Codex completed this turn.", None

    turn_id: str | None = None
    fallback = ""
    for raw in reversed(lines):
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        payload = item.get("payload", {})
        if not isinstance(payload, dict):
            continue
        if payload.get("type") == "task_complete" and not turn_id:
            candidate = payload.get("turn_id")
            turn_id = candidate if isinstance(candidate, str) else None
            message = payload.get("last_agent_message")
            if isinstance(message, str) and message.strip():
                fallback = message.strip()
        if item.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "assistant":
            message = output_text(payload.get("content"))
            if message:
                return message, turn_id
        if item.get("type") == "event_msg" and payload.get("type") == "agent_message":
            message = payload.get("message")
            if isinstance(message, str) and message.strip() and not fallback:
                fallback = message.strip()
    return fallback or "Codex completed this turn.", turn_id


def title_for(cwd: str) -> str:
    leaf = Path(cwd).name or cwd
    return f"Codex completed · {leaf}"


def main() -> int:
    hook = read_hook_input()
    result, transcript_turn_id = latest_completion(hook.get("transcript_path"))
    if len(result) > RESULT_LIMIT:
        result = result[:RESULT_LIMIT] + "\n\n… Result shortened by Cairn's MVP relay."
    session_id = str(hook.get("session_id") or "unknown-session")
    turn_id = str(hook.get("turn_id") or transcript_turn_id or datetime.now(timezone.utc).timestamp())
    cwd = str(hook.get("cwd") or "")
    payload = {
        "id": f"{session_id}:{turn_id}",
        "version": 1,
        "event": "codex.turn.completed",
        "session_id": session_id,
        "turn_id": turn_id,
        "cwd": cwd,
        "title": title_for(cwd),
        "result": result,
        "status": "completed",
        "source": "codex",
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    locator = build_locator()
    if locator:
        payload["locator"] = locator
    try:
        INBOX.mkdir(parents=True, exist_ok=True)
        temporary = INBOX / f".{uuid.uuid4().hex}.pending"
        destination = INBOX / f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{uuid.uuid4().hex}.json"
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, destination)  # The app only observes fully written JSON files.
    except OSError:
        pass  # A completion hook must not make Codex fail when Cairn is closed.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
