#!/usr/bin/env python3
"""Verify every bundled producer against docs/inbox-protocol.md.

The inbox protocol is the part of Cairn meant to be depended on by code that
isn't Cairn, so it needs a test that fails when a bridge drifts from the
document. Each producer runs against a temporary HOME, and what it writes is
checked for both the payload contract (§3) and the publishing contract (§2:
dot-prefixed temporary file, atomic rename, sortable filename, UTF-8, no
leftovers).

    /usr/bin/python3 Tests/protocol_roundtrip.py

Must run under /usr/bin/python3 (3.9 on current macOS), because that is the
interpreter the installed hooks actually invoke.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "Scripts"

sys.path.insert(0, str(SCRIPTS))
from cairn_doctor import validate_payload  # noqa: E402  (needs the path above)

FILENAME = re.compile(r"^\d{8}T\d{6}\d{6}Z-[0-9a-f]{16,}\.json$")

failures: list[str] = []
checks = 0


def check(condition: bool, description: str) -> bool:
    global checks
    checks += 1
    if not condition:
        failures.append(description)
    return condition


def published(inbox: Path, producer: str) -> list[dict[str, Any]]:
    """Read what a producer wrote, asserting the §2 publishing contract."""
    if not inbox.is_dir():
        check(False, f"{producer}: never created the inbox directory")
        return []

    leftovers = list(inbox.glob(".*"))
    check(not leftovers, f"{producer}: left temporary files behind: {leftovers}")

    files = sorted(p for p in inbox.iterdir() if not p.name.startswith("."))
    check(bool(files), f"{producer}: published nothing")

    payloads: list[dict[str, Any]] = []
    for path in files:
        check(
            bool(FILENAME.match(path.name)),
            f"{producer}: filename is not <stamp>-<nonce>.json: {path.name}",
        )
        raw = path.read_bytes()
        check(
            not raw.startswith(b"\xef\xbb\xbf"),
            f"{producer}: wrote a UTF-8 BOM",
        )
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            check(False, f"{producer}: not valid UTF-8 JSON: {error}")
            continue

        reason = validate_payload(payload)
        check(reason is None, f"{producer}: violates the payload contract — {reason}")

        for field in ("source", "turn_id", "user_message", "model", "platform"):
            if field in payload:
                check(
                    payload[field] is not None,
                    f"{producer}: sent {field}=null; §3 says omit instead",
                )
        check(
            len(payload.get("result", "")) <= 50_000,
            f"{producer}: result exceeds the 50,000 character limit",
        )
        payloads.append(payload)
    return payloads


def sandbox() -> tuple[Path, Path, dict[str, str]]:
    home = Path(tempfile.mkdtemp(prefix="cairn-protocol-"))
    inbox = home / "Library" / "Application Support" / "Cairn" / "inbox"
    environment = dict(os.environ, HOME=str(home))
    return home, inbox, environment


def run_producer(script: str, environment: dict[str, str], *args: str, stdin: str = "") -> None:
    finished = subprocess.run(
        [sys.executable, str(SCRIPTS / script), *args],
        input=stdin,
        env=environment,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    # §8.1: a bridge must never fail its host, whatever happens.
    check(
        finished.returncode == 0,
        f"{script}: exited {finished.returncode}, but a bridge must always exit 0 "
        f"({finished.stderr.strip()})",
    )


# --------------------------------------------------------------------------


def test_cairn_save() -> None:
    home, inbox, environment = sandbox()
    try:
        run_producer(
            "cairn_save.py",
            environment,
            "--source",
            "claude-code",
            "--prompt",
            "寻迹功能",
            stdin="结论正文 — non-ASCII must survive verbatim.\n",
        )
        payloads = published(inbox, "cairn_save.py")
        for payload in payloads:
            check(
                "结论正文" in payload["result"],
                "cairn_save.py: mangled non-ASCII text (ensure_ascii must be False)",
            )
            check(
                payload["session_id"].startswith("save:"),
                "cairn_save.py: default session should collapse repeated saves per directory",
            )
            check(
                payload.get("user_message") == "寻迹功能",
                "cairn_save.py: --prompt should become user_message",
            )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_cairn_save_updates_one_note() -> None:
    """§5: two saves from one directory must share a session_id."""
    home, inbox, environment = sandbox()
    try:
        run_producer("cairn_save.py", environment, "first", "--source", "codex")
        run_producer("cairn_save.py", environment, "second", "--source", "codex")
        payloads = published(inbox, "cairn_save.py (repeated)")
        check(len(payloads) == 2, "cairn_save.py: expected two published notes")
        if len(payloads) == 2:
            check(
                payloads[0]["session_id"] == payloads[1]["session_id"],
                "cairn_save.py: repeated saves must share a session_id so the note updates",
            )
            check(
                payloads[0]["id"] != payloads[1]["id"],
                "cairn_save.py: each note needs a distinct id or the second is dropped",
            )

        run_producer("cairn_save.py", environment, "third", "--source", "codex", "--new")
        fresh = published(inbox, "cairn_save.py (--new)")
        check(
            len({p["session_id"] for p in fresh}) == 2,
            "cairn_save.py --new: must produce a distinct session_id",
        )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_claude_hook() -> None:
    home, inbox, environment = sandbox()
    try:
        transcript = home / "transcript.jsonl"
        transcript.write_text(
            "\n".join(
                [
                    json.dumps({"type": "user", "message": {"role": "user", "content": "add a test"}}),
                    json.dumps(
                        {
                            "type": "assistant",
                            "message": {
                                "role": "assistant",
                                "content": [{"type": "text", "text": "stale reply"}],
                            },
                        }
                    ),
                ]
            ),
            encoding="utf-8",
        )
        run_producer(
            "cairn_claude_hook.py",
            environment,
            stdin=json.dumps(
                {
                    "session_id": "abc-123",
                    "transcript_path": str(transcript),
                    "cwd": "/tmp/project",
                    "last_assistant_message": "the real final reply",
                    "model": "claude-opus-5",
                }
            ),
        )
        payloads = published(inbox, "cairn_claude_hook.py")
        for payload in payloads:
            check(
                payload["result"] == "the real final reply",
                "cairn_claude_hook.py: must prefer last_assistant_message over the transcript",
            )
            check(
                payload.get("user_message") == "add a test",
                "cairn_claude_hook.py: should recover the latest user prompt from the transcript",
            )
            check(
                payload["source"] == "claude-code" and payload["session_id"] == "abc-123",
                "cairn_claude_hook.py: source/session must pass through unchanged",
            )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_claude_hook_survives_garbage() -> None:
    """§8.1: no input may make a bridge fail, and none may publish an empty note."""
    home, inbox, environment = sandbox()
    try:
        for stdin in ("", "not json", "[]", json.dumps({"transcript_path": "/nope"})):
            run_producer("cairn_claude_hook.py", environment, stdin=stdin)
        for payload in published(inbox, "cairn_claude_hook.py (degraded)"):
            check(
                bool(payload["result"].strip()),
                "cairn_claude_hook.py: published an empty result",
            )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_codex_hook() -> None:
    home, inbox, environment = sandbox()
    try:
        transcript = home / "codex.jsonl"
        transcript.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "type": "response_item",
                            "payload": {
                                "type": "message",
                                "role": "assistant",
                                "content": [{"type": "output_text", "text": "codex final answer"}],
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "type": "event_msg",
                            "payload": {"type": "task_complete", "turn_id": "turn-9"},
                        }
                    ),
                ]
            ),
            encoding="utf-8",
        )
        run_producer(
            "cairn_codex_hook.py",
            environment,
            stdin=json.dumps(
                {
                    "session_id": "019f9fe6-41d4-7d73-878c-255e57907727",
                    "transcript_path": str(transcript),
                    "cwd": "/tmp/project",
                }
            ),
        )
        for payload in published(inbox, "cairn_codex_hook.py"):
            check(
                payload["result"] == "codex final answer",
                "cairn_codex_hook.py: must extract the final assistant message",
            )
            check(
                payload["source"] == "codex",
                "cairn_codex_hook.py: source must be 'codex'",
            )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_codex_hook_survives_garbage() -> None:
    home, inbox, environment = sandbox()
    try:
        for stdin in ("", "{", json.dumps({"transcript_path": "/does/not/exist"})):
            run_producer("cairn_codex_hook.py", environment, stdin=stdin)
        published(inbox, "cairn_codex_hook.py (degraded)")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_hermes_plugin() -> None:
    """The Hermes bridge is a module, not a script — call its hook directly."""
    home, inbox, _ = sandbox()
    code = """
import json, sys
sys.path.insert(0, {repo!r})
from HermesPlugin import notify_cairn
notify_cairn(
    session_id="hermes-1",
    turn_id="t1",
    user_message="ship it",
    assistant_response="shipped",
    model="hermes-x",
    platform="dashboard",
)
notify_cairn(session_id="hermes-2", assistant_response="   ")
""".format(repo=str(REPO))
    try:
        finished = subprocess.run(
            [sys.executable, "-c", code],
            env=dict(
                os.environ,
                HOME=str(home),
                HERMES_TUI_DASHBOARD="1",
                HERMES_TUI_SIDECAR_URL="ws://127.0.0.1:9119/api/pub?token=secret&channel=chat",
                HERMES_DASHBOARD_PUBLIC_URL="",
                HERMES_HOME=str(home / ".hermes" / "profiles" / "research"),
            ),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        check(
            finished.returncode == 0,
            f"HermesPlugin: raised into its host — {finished.stderr.strip()}",
        )
        payloads = published(inbox, "HermesPlugin")
        check(
            len(payloads) == 1,
            "HermesPlugin: an empty assistant_response must publish nothing (§8.3)",
        )
        for payload in payloads:
            check(
                payload["source"] == "hermes" and payload["platform"] == "dashboard",
                "HermesPlugin: source/platform must pass through",
            )
            check(
                payload.get("locator", {}).get("web_url")
                == "http://127.0.0.1:9119?profile=research",
                "HermesPlugin: dashboard turns must preserve a credential-free web URL",
            )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_validator_rejects_what_cairn_rejects() -> None:
    """The doctor's validator is only useful if it matches the app's decoder."""
    valid = {
        "id": "a",
        "version": 1,
        "event": "x.turn.completed",
        "session_id": "s",
        "cwd": "",
        "title": "t",
        "result": "r",
        "status": "completed",
        "timestamp": "2026-07-27T00:00:00Z",
    }
    check(validate_payload(valid) is None, "validator: rejected a valid payload")
    check(
        validate_payload(dict(valid, timestamp="2026-07-27T00:00:00.123456Z")) is None,
        "validator: rejected fractional seconds, which the app accepts",
    )
    check(
        validate_payload(dict(valid, timestamp="2026-07-27T00:00:00+00:00")) is None,
        "validator: rejected a +00:00 offset, which the app accepts",
    )
    for field in valid:
        broken = dict(valid)
        del broken[field]
        check(
            validate_payload(broken) is not None,
            f"validator: accepted a payload missing required field '{field}'",
        )
    check(
        validate_payload(dict(valid, version="1")) is not None,
        "validator: accepted a string version",
    )
    check(
        validate_payload(dict(valid, version=True)) is not None,
        "validator: accepted a boolean version",
    )
    check(
        validate_payload(dict(valid, timestamp="27 July 2026")) is not None,
        "validator: accepted a non-RFC-3339 timestamp",
    )
    check(validate_payload([]) is not None, "validator: accepted a JSON array")


def main() -> int:
    for test in (
        test_validator_rejects_what_cairn_rejects,
        test_cairn_save,
        test_cairn_save_updates_one_note,
        test_claude_hook,
        test_claude_hook_survives_garbage,
        test_codex_hook,
        test_codex_hook_survives_garbage,
        test_hermes_plugin,
    ):
        print(f"· {test.__name__}")
        test()

    print()
    if failures:
        print(f"{len(failures)} of {checks} checks failed:")
        for failure in failures:
            print(f"  ✗ {failure}")
        print("\nSee docs/inbox-protocol.md — either the bridge or the document is wrong.")
        return 1
    print(f"All {checks} protocol checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
