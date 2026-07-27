#!/usr/bin/env python3
"""Save a note to Cairn's floating queue, on purpose.

The Stop hooks record turns automatically; this tool is the deliberate
counterpart — an agent (or a human) saves a conclusion worth keeping:

    cairn_save.py --source claude-code --prompt "寻迹功能" "结论正文……"
    echo "结论正文" | cairn_save.py --source codex

By default every save from the same directory updates one note per source
(session "save:<dir>"), so repeated saves stay tidy; pass --new for a
distinct note. Text comes from the argument or stdin. A locator is captured
so the saved note can trail back to the window it was saved from.

Exit code is always 0 with a message on stderr for failures: saving a note
must never break an agent's run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

INBOX = Path.home() / "Library" / "Application Support" / "Cairn" / "inbox"
RESULT_LIMIT = 50_000

try:
    from cairn_locator import build_locator
except Exception:  # the locator is optional; saving must never break without it
    def build_locator() -> dict[str, Any]:
        return {}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Save a note to Cairn")
    parser.add_argument("text", nargs="?", help="note body; stdin when omitted")
    parser.add_argument("--source", default="note",
                        help="which agent is saving (codex, claude-code, hermes, …)")
    parser.add_argument("--prompt", default="",
                        help="one-line topic shown as the note's bold headline")
    parser.add_argument("--session", default="",
                        help="explicit session id; default is one note per directory")
    parser.add_argument("--cwd", default="", help="working directory the note belongs to")
    parser.add_argument("--new", action="store_true",
                        help="always create a distinct note instead of updating")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    text = args.text if args.text is not None else sys.stdin.read()
    text = text.strip()
    if not text:
        print("cairn_save: nothing to save", file=sys.stderr)
        return 0
    if len(text) > RESULT_LIMIT:
        text = text[:RESULT_LIMIT] + "\n\n… Note shortened by Cairn."

    cwd = args.cwd or os.getcwd()
    leaf = Path(cwd).name or "notes"
    session = args.session or (uuid.uuid4().hex if args.new else f"save:{leaf}")
    turn = uuid.uuid4().hex
    source = args.source.strip().lower() or "note"

    payload: dict[str, Any] = {
        "id": f"{source}:{session}:{turn}",
        "version": 1,
        "event": f"{source}.note.saved",
        "session_id": session,
        "turn_id": turn,
        "cwd": cwd,
        "title": f"Saved to Cairn · {leaf}",
        "result": text,
        "status": "completed",
        "source": source,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if args.prompt.strip():
        payload["user_message"] = args.prompt.strip()
    locator = build_locator()
    if locator:
        payload["locator"] = locator

    try:
        INBOX.mkdir(parents=True, exist_ok=True)
        nonce = uuid.uuid4().hex
        temporary = INBOX / f".{nonce}.pending"
        destination = INBOX / (
            f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}-{nonce}.json"
        )
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, destination)
        print(f"Saved to Cairn: {leaf} ({source})")
    except OSError as error:
        print(f"cairn_save: could not save: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
