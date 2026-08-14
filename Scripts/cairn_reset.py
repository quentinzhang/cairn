#!/usr/bin/env python3
"""Put this Mac back to the state it was in before Cairn ever ran.

Onboarding is the one part of an app you cannot test twice by accident: the
offer to connect agents shows once, and after that every launch is a returning
user's launch. This walks all of it back —
connections, notes, preferences — so the next launch is a first launch again.

    python3 Scripts/cairn_reset.py           # say what would happen, change nothing
    python3 Scripts/cairn_reset.py --yes     # do it
    python3 Scripts/cairn_reset.py --yes --keep-notes
    python3 Scripts/cairn_reset.py --yes --keep-permissions

It does NOT delete Cairn.app: the point is to reinstall the *state*, not the
program. Everything else goes, the privacy grants included — a machine that
never ran Cairn has no TCC rows for it, and the first-run flow being tested
includes the moment those permissions are asked for. `--keep-permissions`
spares them when re-answering the system prompts is the tedious part.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Tuple

import cairn_connect

HOME = Path.home()
BUNDLE_ID = "app.cairn.Cairn"
SUPPORT = HOME / "Library" / "Application Support" / "Cairn"
INBOX = SUPPORT / "inbox"
STORE = SUPPORT / "completions.json"
# Everything Cairn has ever asked macOS to remember on its behalf.
TCC_SERVICES = ("Accessibility", "AppleEvents")


def tilde(path: object) -> str:
    text = str(path)
    home = str(HOME)
    if text == home:
        return "~"
    if text.startswith(home + os.sep):
        return "~" + text[len(home) :]
    return text


def running_app_pids() -> List[int]:
    finished = subprocess.run(
        ["/usr/bin/pgrep", "-f", "Cairn.app/Contents/MacOS/cairn"],
        capture_output=True,
        text=True,
        check=False,
    )
    return [int(line) for line in finished.stdout.split() if line.isdigit()]


def preference_keys() -> List[str]:
    """Cairn's own preference keys — parsed as a plist, not as printed text.

    `defaults read` indents nested dictionaries the same way it indents the
    top level, so scraping its output counts a browser affinity entry as a
    preference of its own.
    """
    finished = subprocess.run(
        ["/usr/bin/defaults", "export", BUNDLE_ID, "-"],
        capture_output=True,
        check=False,
    )
    if finished.returncode != 0:
        return []
    try:
        payload = plistlib.loads(finished.stdout)
    except Exception:
        return []
    return sorted(payload) if isinstance(payload, dict) else []


def note_count() -> int:
    try:
        payload = json.loads(STORE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    return len(payload) if isinstance(payload, list) else 0


def connected_runtimes() -> List[Tuple[str, str]]:
    report = cairn_connect.status_report()
    return [
        (item["id"], item["state"])
        for item in report["runtimes"]
        if item["state"]
        in {
            cairn_connect.CONNECTED,
            cairn_connect.ATTENTION,
            cairn_connect.RESTART_TO_CONNECT,
            cairn_connect.RESTART_TO_DISCONNECT,
        }
    ]


def plan(reset_tcc: bool, keep_notes: bool) -> List[str]:
    lines: List[str] = []

    pids = running_app_pids()
    if pids:
        lines.append("quit Cairn (pid %s)" % ", ".join(str(pid) for pid in pids))

    wired = connected_runtimes()
    for identifier, state in wired:
        lines.append("disconnect %s (currently %s)" % (identifier, state))
    if not wired:
        lines.append("no agent is connected — nothing to disconnect")

    if keep_notes:
        lines.append("keep %s (--keep-notes)" % tilde(SUPPORT))
    elif SUPPORT.exists():
        notes = note_count()
        pending = len(list(INBOX.glob("*"))) if INBOX.is_dir() else 0
        lines.append(
            "delete %s (%d note(s) in the queue, %d file(s) in the inbox)"
            % (tilde(SUPPORT), notes, pending)
        )

    keys = preference_keys()
    if keys:
        lines.append(
            "clear %d preference(s) in %s: %s" % (len(keys), BUNDLE_ID, ", ".join(keys))
        )
    else:
        lines.append("no preferences stored — the next launch already behaves as first-run")

    if reset_tcc:
        lines.append(
            "revoke %s for %s (macOS will ask again)"
            % (" and ".join(TCC_SERVICES), BUNDLE_ID)
        )
    else:
        lines.append("keep the Accessibility and Automation grants (--keep-permissions)")

    return lines


def quit_app() -> None:
    """Stop every running copy, and wait until it is actually stopped.

    Order matters more than it looks: disconnecting OpenClaw restarts its
    gateway and can take half a minute, and a copy of Cairn that comes back
    during that window will recreate its inbox and rewrite the preference this
    reset is about to clear. So this runs immediately before the local state is
    removed, not once at the top — and it confirms the process is gone rather
    than assuming a signal was enough.
    """
    for pid in running_app_pids():
        subprocess.run(["/bin/kill", str(pid)], check=False)
        print("quit Cairn (pid %d)" % pid)

    for _ in range(20):
        if not running_app_pids():
            return
        time.sleep(0.25)

    for pid in running_app_pids():
        subprocess.run(["/bin/kill", "-9", str(pid)], check=False)
        print("forced Cairn to quit (pid %d)" % pid)


def apply(reset_tcc: bool, keep_notes: bool) -> int:
    failures = 0

    quit_app()

    for identifier, _ in connected_runtimes():
        try:
            outcome = cairn_connect.DISCONNECT[identifier]()
        except Exception as error:  # a stuck CLI must not block the rest
            print("could not disconnect %s: %s" % (identifier, error), file=sys.stderr)
            failures += 1
            continue
        status = "ok" if outcome["ok"] else "failed"
        print("disconnect %s: %s" % (identifier, status))
        if not outcome["ok"]:
            failures += 1

    # Anything above here can take a while and can bring Cairn back with it.
    quit_app()

    if not keep_notes and SUPPORT.exists():
        try:
            shutil.rmtree(SUPPORT)
            print("deleted %s" % tilde(SUPPORT))
        except OSError as error:
            print("could not delete %s: %s" % (tilde(SUPPORT), error), file=sys.stderr)
            failures += 1

    if preference_keys():
        # `defaults delete` rather than removing the plist: cfprefsd owns the
        # file and would write the cached copy back over a deleted one.
        subprocess.run(["/usr/bin/defaults", "delete", BUNDLE_ID], check=False)
        print("cleared preferences for %s" % BUNDLE_ID)

    if reset_tcc:
        for service in TCC_SERVICES:
            finished = subprocess.run(
                ["/usr/bin/tccutil", "reset", service, BUNDLE_ID],
                capture_output=True,
                text=True,
                check=False,
            )
            if finished.returncode == 0:
                print("revoked %s" % service)
            else:
                print(
                    "could not revoke %s: %s"
                    % (service, (finished.stdout + finished.stderr).strip()),
                    file=sys.stderr,
                )
                failures += 1

    if running_app_pids():
        print(
            "Cairn started again before the reset finished — quit it and re-run.",
            file=sys.stderr,
        )
        failures += 1
    elif preference_keys():
        print(
            "preferences reappeared after being cleared — something rewrote them.",
            file=sys.stderr,
        )
        failures += 1

    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reset Cairn to its first-run state")
    parser.add_argument("--yes", action="store_true", help="actually make the changes")
    parser.add_argument("--keep-notes", action="store_true", help="keep the note queue")
    parser.add_argument(
        "--keep-permissions",
        action="store_true",
        help="keep the Accessibility and Automation grants instead of revoking them",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cairn_connect.prepare_environment()

    steps = plan(reset_tcc=not args.keep_permissions, keep_notes=args.keep_notes)

    if not args.yes:
        print("\nThis would:\n")
        for step in steps:
            print("  · %s" % step)
        print("\nNothing has changed. Re-run with --yes to do it.\n")
        return 0

    failures = apply(reset_tcc=not args.keep_permissions, keep_notes=args.keep_notes)
    print("")
    if failures:
        print("%d step(s) failed — see above." % failures)
    print("Open Cairn to start over: open /Applications/Cairn.app")
    print("")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
