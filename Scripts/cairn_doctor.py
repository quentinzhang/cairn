#!/usr/bin/env python3
"""Check every piece of Cairn's wiring and say exactly what is wrong.

Cairn has no server and no error channel: a bridge that fails, fails silently
by design (a completion hook must never break the agent it runs inside). That
tradeoff is right, and it means the only way a user learns their setup is
broken is that notes stop arriving. This is the tool that tells them why.

    python3 Scripts/cairn_doctor.py            # check everything
    python3 Scripts/cairn_doctor.py --probe    # also publish a real test note
    python3 Scripts/cairn_doctor.py --json     # machine-readable

Output contains no note bodies or prompts, and the home directory is always
shown as `~`. Operational App and checkout paths remain because they are part
of the diagnosis; review them before pasting the report into a public issue.

Exit code is 0 when nothing is broken, 1 when a check FAILs.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cairn_payload import ensure_private_inbox, payload_path, write_private_text
import install_deepseek_harness_plugin

HOME = Path.home()
# The checkout root when run from a checkout; Contents/ when run from inside
# an installed app. Only ever used to name the developer's tree — everything
# that has to resolve in both layouts goes through SCRIPTS or payload_path.
REPO = Path(__file__).resolve().parent.parent
SCRIPTS = Path(__file__).resolve().parent
SUPPORT = HOME / "Library" / "Application Support" / "Cairn"
INBOX = SUPPORT / "inbox"
STORE = SUPPORT / "completions.json"

CODEX_HOOKS = HOME / ".codex" / "hooks.json"
CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
HERMES_PLUGIN = HOME / ".hermes" / "plugins" / "cairn"
OPENCODE_PLUGIN = HOME / ".config" / "opencode" / "plugins" / "cairn.js"
OPENCLAW_CONFIG = Path(
    os.environ.get("OPENCLAW_CONFIG_PATH", HOME / ".openclaw" / "openclaw.json")
).expanduser()

HOOK_INTERPRETER = Path("/usr/bin/python3")
STALE_AFTER_SECONDS = 120

REQUIRED_FIELDS = {
    "id": str,
    "version": int,
    "event": str,
    "session_id": str,
    "cwd": str,
    "title": str,
    "result": str,
    "status": str,
    "timestamp": str,
}

OK, WARN, FAIL, INFO = "ok", "warn", "fail", "info"
GLYPH = {OK: "✓", WARN: "!", FAIL: "✗", INFO: "·"}


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------


class Report:
    """Collects results grouped by section, in the order they were added."""

    def __init__(self) -> None:
        self.sections: list[tuple[str, list[dict[str, Any]]]] = []
        self._current: list[dict[str, Any]] | None = None

    def section(self, title: str) -> None:
        self._current = []
        self.sections.append((title, self._current))

    def add(self, level: str, label: str, detail: str = "", fix: str = "") -> None:
        assert self._current is not None, "add() before section()"
        entry: dict[str, Any] = {"level": level, "label": label}
        if detail:
            entry["detail"] = detail
        if fix:
            entry["fix"] = fix
        self._current.append(entry)

    @property
    def failures(self) -> int:
        return sum(
            1 for _, entries in self.sections for e in entries if e["level"] == FAIL
        )

    @property
    def warnings(self) -> int:
        return sum(
            1 for _, entries in self.sections for e in entries if e["level"] == WARN
        )

    def render(self) -> str:
        lines: list[str] = []
        for title, entries in self.sections:
            if not entries:
                continue
            lines.append("")
            lines.append(title)
            lines.append("─" * max(len(title), 12))
            for entry in entries:
                lines.append(f"  {GLYPH[entry['level']]} {entry['label']}")
                if entry.get("detail"):
                    for line in entry["detail"].splitlines():
                        lines.append(f"      {line}")
                if entry.get("fix"):
                    lines.append(f"      → {entry['fix']}")
        lines.append("")
        if self.failures:
            lines.append(
                f"{self.failures} failing, {self.warnings} warning(s). "
                "Fix the ✗ lines above; each one stops notes from arriving."
            )
        elif self.warnings:
            lines.append(
                f"No failures, {self.warnings} warning(s). "
                "Cairn works; the ! lines are optional or not-yet-configured."
            )
        else:
            lines.append("Everything checks out.")
        lines.append("")
        return "\n".join(lines)


def tilde(path: Any) -> str:
    """Render a path with the home directory collapsed, so output is pasteable."""
    text = str(path)
    home = str(HOME)
    if text == home:
        return "~"
    if text.startswith(home + os.sep):
        return "~" + text[len(home) :]
    return text


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def read_json(path: Path) -> tuple[Any, str | None]:
    """Return (parsed, error). Missing file is (None, None), not an error."""
    if not path.exists():
        return None, None
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except json.JSONDecodeError as error:
        return None, f"invalid JSON at line {error.lineno}: {error.msg}"
    except OSError as error:
        return None, str(error)


def run(command: list[str], timeout: int = 15) -> tuple[int, str]:
    try:
        finished = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, check=False
        )
        return finished.returncode, (finished.stdout + finished.stderr).strip()
    except (OSError, subprocess.SubprocessError) as error:
        return 127, str(error)


def stop_handlers(config: Any) -> list[dict[str, Any]]:
    """Flatten a Codex/Claude-shaped hooks.Stop tree into a list of handlers."""
    hooks = config.get("hooks") if isinstance(config, dict) else None
    stop = hooks.get("Stop") if isinstance(hooks, dict) else None
    if not isinstance(stop, list):
        return []
    handlers: list[dict[str, Any]] = []
    for group in stop:
        entries = group.get("hooks") if isinstance(group, dict) else None
        if isinstance(entries, list):
            handlers.extend(h for h in entries if isinstance(h, dict))
    return handlers


def referenced_scripts(handler: dict[str, Any]) -> list[Path]:
    """Every existing-looking .py path mentioned by a hook handler."""
    blob = " ".join(
        [str(handler.get("command", ""))]
        + [str(a) for a in handler.get("args", []) if isinstance(a, (str, int))]
    )
    return [Path(m) for m in re.findall(r"/[^\s\"']+\.py", blob)]


def in_app_bundle(path: Path) -> bool:
    """True for a path inside an installed Cairn.app.

    `build_app.sh` copies the bridge scripts and both plugins into
    Contents/Resources, so a released install legitimately runs its hooks from
    inside the bundle rather than from a source checkout. That is the normal
    end-user shape, not a misconfiguration.
    """
    return any(part == "Cairn.app" for part in path.parts)


def check_hook_script(report: Report, runtime: str, scripts: list[Path], expected: str) -> None:
    """A hook is only real if the script it points at still exists."""
    target = SCRIPTS / expected
    for script in scripts:
        if not script.exists():
            report.add(
                FAIL,
                f"{runtime} hook points at a missing script",
                f"{tilde(script)}\n"
                "The hook is registered but the file is gone — every turn runs a\n"
                "no-op. This is what happens after the repo is moved, renamed, or\n"
                "the app it lived inside was deleted.",
                f"python3 {tilde(SCRIPTS / ('install_' + runtime + '_hook.py'))} install",
            )
            continue
        if script.resolve() == target.resolve():
            continue
        if in_app_bundle(script):
            report.add(INFO, f"Runs from the installed app bundle: {tilde(script)}")
        else:
            report.add(
                WARN,
                f"{runtime} hook runs a script from somewhere else",
                f"registered: {tilde(script.resolve())}\nthis repo:  {tilde(target)}\n"
                "Turns are published by that copy, so edits here have no effect.",
                "Reinstall from this checkout if that is the one you are editing.",
            )


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------


def check_environment(report: Report) -> None:
    report.section("Environment")

    system = platform.system()
    if system != "Darwin":
        report.add(
            FAIL,
            f"Not macOS (platform: {system})",
            "Cairn's app is macOS-only. The inbox protocol is portable, but this\n"
            "app, the trail-back resolver, and these installers are not.",
        )
        return

    code, version = run(["sw_vers", "-productVersion"])
    version = version if code == 0 else "unknown"
    major = int(version.split(".")[0]) if version.split(".")[0].isdigit() else 0
    if major and major < 14:
        report.add(
            FAIL,
            f"macOS {version} is below the minimum",
            "Cairn requires macOS 14 (Sonoma) or newer.",
        )
    else:
        report.add(OK, f"macOS {version}")

    report.add(INFO, f"Running from: {tilde(SCRIPTS)}")

    if HOOK_INTERPRETER.exists():
        code, out = run([str(HOOK_INTERPRETER), "--version"])
        report.add(OK, f"Hook interpreter: {HOOK_INTERPRETER} ({out or 'unknown'})")
    else:
        report.add(
            FAIL,
            f"Hook interpreter missing: {HOOK_INTERPRETER}",
            "Every installed hook invokes this absolute path. Without it, no\n"
            "bridge can run.",
            "Install Apple's command line tools: xcode-select --install",
        )

    for script in ("cairn_locator.py", "cairn_save.py"):
        path = SCRIPTS / script
        if not path.is_file():
            report.add(FAIL, f"Missing from this checkout: Scripts/{script}")


def check_app(report: Report) -> None:
    report.section("Application")

    candidates = [
        Path("/Applications/Cairn.app"),
        HOME / "Applications" / "Cairn.app",
        REPO / "dist" / "Cairn.app",
    ]
    installed = [path for path in candidates if path.is_dir()]

    if not installed:
        report.add(
            FAIL,
            "Cairn.app not found",
            "Looked in /Applications, ~/Applications, and dist/.\n"
            "Notes published while Cairn is absent are not lost — they queue in\n"
            "the inbox — but nothing will display them.",
            "./Scripts/build_app.sh && open dist/Cairn.app",
        )
    for path in installed:
        version = "unknown"
        try:
            with (path / "Contents" / "Info.plist").open("rb") as handle:
                version = plistlib.load(handle).get("CFBundleShortVersionString", "unknown")
        except (OSError, plistlib.InvalidFileException, ValueError):
            pass
        report.add(OK, f"Installed: {tilde(path)} (version {version})")

    if len(installed) > 1:
        report.add(
            WARN,
            "More than one Cairn.app on disk",
            "Both copies watch the same inbox, and whichever polls first wins the\n"
            "note. Keep one, or expect notes to appear in the build you are not\n"
            "looking at.",
            "Quit and delete the copies you are not using.",
        )

    code, out = run(["/usr/bin/pgrep", "-x", "cairn"])
    if code == 0 and out:
        report.add(OK, f"Running (pid {out.split()[0]})")
    else:
        report.add(
            WARN,
            "Cairn is not running",
            "The inbox will not be drained until it launches.",
            "open /Applications/Cairn.app",
        )


def validate_payload(payload: Any) -> str | None:
    """Return the first reason Cairn would refuse this payload, or None."""
    if not isinstance(payload, dict):
        return "top level is not a JSON object"
    for field, expected in REQUIRED_FIELDS.items():
        if field not in payload:
            return f"missing required field '{field}'"
        value = payload[field]
        # bool is an int subclass; version must be a real number.
        if expected is int and isinstance(value, bool):
            return f"field '{field}' must be an integer, got a boolean"
        if not isinstance(value, expected):
            return (
                f"field '{field}' must be {expected.__name__}, "
                f"got {type(value).__name__}"
            )
    stamp = payload["timestamp"]
    if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$", stamp):
        return f"field 'timestamp' is not RFC 3339: {stamp!r}"
    return None


def check_inbox(report: Report) -> None:
    report.section("Inbox")

    if not INBOX.is_dir():
        report.add(
            INFO,
            f"{tilde(INBOX)} does not exist yet",
            "Created on first publish or on app launch — not an error before either\n"
            "has happened.",
        )
        return

    mode = INBOX.stat().st_mode & 0o777
    if mode == 0o700:
        report.add(OK, f"{tilde(INBOX)} (mode 700)")
    else:
        report.add(
            WARN,
            f"{tilde(INBOX)} has mode {mode:o}, expected 700",
            "The inbox holds plaintext agent output. Cairn creates it 0700; a wider\n"
            "mode means something else created or changed it.",
            f"chmod 700 {tilde(INBOX)}",
        )

    now = time.time()
    notes = sorted(p for p in INBOX.glob("*.json") if not p.name.startswith("."))
    pending = list(INBOX.glob(".*.pending"))

    fresh = [p for p in notes if now - p.stat().st_mtime <= STALE_AFTER_SECONDS]
    stale = [p for p in notes if now - p.stat().st_mtime > STALE_AFTER_SECONDS]

    if fresh:
        report.add(INFO, f"{len(fresh)} note(s) waiting, all recent — normal in flight")

    if stale:
        # Cairn deletes what it accepts, so an old file is a rejected file.
        broken: list[str] = []
        for path in stale[:5]:
            payload, error = read_json(path)
            reason = error or validate_payload(payload)
            if reason:
                broken.append(f"{path.name}: {reason}")
        if broken:
            report.add(
                FAIL,
                f"{len(stale)} undeliverable note(s) stuck in the inbox",
                "Cairn deletes a note the moment it accepts one, so these were\n"
                "rejected. A rejected file is retried every 400ms forever — this is\n"
                "litter, and it means a producer is emitting invalid payloads.\n\n"
                + "\n".join(broken)
                + ("\n… and more" if len(stale) > 5 else "")
                + "\n\nSee docs/inbox-protocol.md §3 for the required shape.",
                f"Delete them once the producer is fixed: rm {tilde(INBOX)}/*.json",
            )
        else:
            report.add(
                WARN,
                f"{len(stale)} valid note(s) waiting, none recent",
                "These parse correctly, so Cairn simply is not draining the inbox.\n"
                "Expected if the app is not running.",
                "Launch Cairn; they will appear within a second.",
            )

    if pending:
        old = [p for p in pending if now - p.stat().st_mtime > STALE_AFTER_SECONDS]
        if old:
            report.add(
                WARN,
                f"{len(old)} abandoned temporary file(s)",
                "A .pending file is written before the atomic rename. Leftovers mean\n"
                "a producer died mid-publish. They are invisible to Cairn and\n"
                "harmless, but they accumulate.",
                f"rm {tilde(INBOX)}/.*.pending",
            )

    if not notes and not pending:
        report.add(OK, "Empty — everything published so far was delivered")

    payload, error = read_json(STORE)
    if error:
        report.add(
            WARN,
            "completions.json is unreadable",
            f"{error}\nCairn falls back to an empty queue; history is lost, nothing\nelse breaks.",
            f"rm {tilde(STORE)}",
        )
    elif isinstance(payload, list):
        report.add(INFO, f"{len(payload)} note(s) in the queue (cap 50)")


def check_codex(report: Report) -> None:
    report.section("Codex")

    if not (HOME / ".codex").is_dir():
        report.add(INFO, "Codex is not installed — skipped")
        return

    config, error = read_json(CODEX_HOOKS)
    if error:
        report.add(
            FAIL,
            f"{tilde(CODEX_HOOKS)} is not valid JSON",
            f"{error}\nCodex ignores the whole file, so no hook of yours runs.",
        )
        return
    if config is None:
        report.add(
            WARN,
            "No Codex hooks configured",
            f"{tilde(CODEX_HOOKS)} does not exist.",
            f"python3 {tilde(SCRIPTS / 'install_codex_hook.py')} install",
        )
        return

    handlers = stop_handlers(config)
    ours = [h for h in handlers if "cairn_codex_hook.py" in str(h.get("command", ""))]
    if not ours:
        report.add(
            WARN,
            "Cairn's Stop hook is not registered",
            f"{len(handlers)} other Stop handler(s) present and untouched.",
            f"python3 {tilde(SCRIPTS / 'install_codex_hook.py')} install",
        )
        return

    report.add(OK, f"Stop hook registered in {tilde(CODEX_HOOKS)}")
    if len(ours) > 1:
        report.add(
            WARN,
            f"{len(ours)} copies of Cairn's Stop hook",
            "Each one publishes the same turn, so you get duplicate notes.",
            f"python3 {tilde(SCRIPTS / 'install_codex_hook.py')} uninstall  # then install once",
        )
    for handler in ours:
        check_hook_script(report, "codex", referenced_scripts(handler), "cairn_codex_hook.py")

    report.add(
        INFO,
        "Codex will not run an untrusted hook",
        "This check cannot see trust state. If notes never arrive and everything\n"
        "above is ✓, run /hooks inside Codex and trust the Cairn handler.",
    )


def check_claude_code(report: Report) -> None:
    report.section("Claude Code")

    if not (HOME / ".claude").is_dir():
        report.add(INFO, "Claude Code is not installed — skipped")
        return

    config, error = read_json(CLAUDE_SETTINGS)
    if error:
        report.add(
            FAIL,
            f"{tilde(CLAUDE_SETTINGS)} is not valid JSON",
            f"{error}\nClaude Code cannot load your settings at all — this breaks more\n"
            "than Cairn.",
        )
        return
    if config is None:
        report.add(
            WARN,
            "No Claude Code settings file",
            f"{tilde(CLAUDE_SETTINGS)} does not exist.",
            f"python3 {tilde(SCRIPTS / 'install_claude_hook.py')} install",
        )
        return

    handlers = stop_handlers(config)
    ours = [
        h
        for h in handlers
        if any("cairn_claude_hook.py" in str(p) for p in referenced_scripts(h))
    ]
    if not ours:
        report.add(
            WARN,
            "Cairn's Stop hook is not registered",
            f"{len(handlers)} other Stop handler(s) present and untouched.",
            f"python3 {tilde(SCRIPTS / 'install_claude_hook.py')} install",
        )
        return

    report.add(OK, f"Stop hook registered in {tilde(CLAUDE_SETTINGS)}")
    if len(ours) > 1:
        report.add(
            WARN,
            f"{len(ours)} copies of Cairn's Stop hook",
            "Each one publishes the same turn, so you get duplicate notes.",
            f"python3 {tilde(SCRIPTS / 'install_claude_hook.py')} uninstall  # then install once",
        )
    for handler in ours:
        check_hook_script(report, "claude", referenced_scripts(handler), "cairn_claude_hook.py")


def check_hermes(report: Report) -> None:
    report.section("Hermes")

    if not (HOME / ".hermes").is_dir() and not run(["/usr/bin/which", "hermes"])[0] == 0:
        report.add(INFO, "Hermes is not installed — skipped")
        return

    source = payload_path("HermesPlugin")
    if not HERMES_PLUGIN.exists() and not HERMES_PLUGIN.is_symlink():
        report.add(
            WARN,
            "Cairn's Hermes plugin is not installed",
            f"{tilde(HERMES_PLUGIN)} does not exist.",
            f"python3 {tilde(SCRIPTS / 'install_hermes_plugin.py')}",
        )
        return

    if HERMES_PLUGIN.is_symlink():
        try:
            target = HERMES_PLUGIN.resolve(strict=True)
        except OSError:
            report.add(
                FAIL,
                "Hermes plugin is a broken symlink",
                f"{tilde(HERMES_PLUGIN)} → {os.readlink(HERMES_PLUGIN)}\n"
                "Hermes will fail to load it. This is what a moved checkout looks like.",
                f"rm {tilde(HERMES_PLUGIN)} && python3 {tilde(SCRIPTS / 'install_hermes_plugin.py')}",
            )
            return
        if target == source.resolve():
            report.add(OK, f"Plugin linked: {tilde(HERMES_PLUGIN)} → {tilde(source)}")
        elif in_app_bundle(target):
            report.add(INFO, f"Plugin linked into the installed app bundle: {tilde(target)}")
        else:
            report.add(
                WARN,
                "Hermes plugin points somewhere else",
                f"linked:    {tilde(target)}\nthis repo: {tilde(source)}\n"
                "Turns are published by that copy, so edits here have no effect.",
            )
    else:
        report.add(
            INFO,
            f"Plugin present as a real directory: {tilde(HERMES_PLUGIN)}",
            "The installer creates a symlink; a copy will not pick up your edits.",
        )

    code, out = run(["hermes", "plugins", "list"])
    if code != 0:
        report.add(
            INFO,
            "Could not ask Hermes whether the plugin is enabled",
            "The `hermes` CLI is not on PATH here. Installing the plugin and\n"
            "enabling it are separate steps.",
        )
    elif "cairn" in out.lower():
        report.add(OK, "Hermes lists the cairn plugin")
    else:
        report.add(
            WARN,
            "Hermes does not list the cairn plugin",
            "Linked but not enabled, so post_llm_call never fires.",
            "hermes plugins enable cairn",
        )


def check_openclaw(report: Report) -> None:
    report.section("OpenClaw")

    if not OPENCLAW_CONFIG.parent.is_dir():
        report.add(INFO, "OpenClaw is not installed — skipped")
        return

    config, error = read_json(OPENCLAW_CONFIG)
    if error:
        report.add(FAIL, f"{tilde(OPENCLAW_CONFIG)} is not valid JSON", error)
        return
    if config is None:
        report.add(
            WARN,
            "No OpenClaw config",
            f"{tilde(OPENCLAW_CONFIG)} does not exist.",
            f"python3 {tilde(SCRIPTS / 'install_openclaw_plugin.py')} install",
        )
        return

    plugins = config.get("plugins") if isinstance(config, dict) else None
    entries = plugins.get("entries") if isinstance(plugins, dict) else None
    entry = entries.get("cairn") if isinstance(entries, dict) else None

    if not isinstance(entry, dict):
        report.add(
            WARN,
            "Cairn's OpenClaw plugin is not configured",
            "No plugins.entries.cairn in the config.",
            f"python3 {tilde(SCRIPTS / 'install_openclaw_plugin.py')} install",
        )
        return

    if entry.get("enabled") is True:
        report.add(OK, "plugins.entries.cairn.enabled = true")
    else:
        report.add(
            FAIL,
            "The plugin is registered but disabled",
            "agent_end will not fire, so no OpenClaw turn is published.",
            f"python3 {tilde(SCRIPTS / 'install_openclaw_plugin.py')} install",
        )

    entry_hooks = entry.get("hooks")
    hooks = entry_hooks if isinstance(entry_hooks, dict) else {}
    if hooks.get("allowConversationAccess") is True:
        report.add(OK, "Conversation access granted")
    else:
        report.add(
            INFO,
            "Conversation access not granted",
            "Newer OpenClaw builds require this for the plugin to read the final\n"
            "assistant message; older builds have no such setting and are fine.\n"
            "Cairn keeps only the last user prompt and the final reply.",
            f"python3 {tilde(SCRIPTS / 'install_openclaw_plugin.py')} install --allow-conversation-access",
        )

    source = payload_path("OpenClawPlugin")
    installs = plugins.get("installs") if isinstance(plugins, dict) else None
    install = installs.get("cairn") if isinstance(installs, dict) else None
    linked = []
    if isinstance(install, dict):
        linked = [
            install[key]
            for key in ("sourcePath", "installPath")
            if isinstance(install.get(key), str)
        ]
    load = plugins.get("load") if isinstance(plugins, dict) else None
    paths = load.get("paths") if isinstance(load, dict) else None
    if isinstance(paths, list):
        linked.extend(p for p in paths if isinstance(p, str))

    resolved = {Path(p).expanduser().resolve() for p in linked}
    if not resolved:
        report.add(INFO, "No plugin source path recorded in the config")
    elif source.resolve() in resolved:
        report.add(OK, f"Loaded from {tilde(source)}")
        if not (source / "index.js").is_file():
            report.add(FAIL, f"Missing plugin entry point: {tilde(source / 'index.js')}")
    elif any(in_app_bundle(path) for path in resolved):
        report.add(
            INFO,
            "Loaded from the installed app bundle",
            ", ".join(sorted(tilde(p) for p in resolved)),
        )
    else:
        report.add(
            WARN,
            "OpenClaw loads the plugin from somewhere else",
            "configured: "
            + ", ".join(sorted(tilde(p) for p in resolved))
            + f"\nthis repo:  {tilde(source)}\n"
            "Turns are published by that copy, so edits here have no effect.",
        )

    for path in sorted(resolved):
        if not path.exists():
            report.add(
                FAIL,
                "OpenClaw's configured plugin path no longer exists",
                f"{tilde(path)}\nOpenClaw cannot load it, so no turn is published.",
                f"python3 {tilde(SCRIPTS / 'install_openclaw_plugin.py')} install",
            )


def check_opencode(report: Report) -> None:
    report.section("OpenCode")

    if not (HOME / ".config" / "opencode").is_dir() and run(
        ["/usr/bin/which", "opencode"]
    )[0] != 0:
        report.add(INFO, "OpenCode is not installed — skipped")
        return

    source = payload_path("OpenCodePlugin") / "index.js"
    if not OPENCODE_PLUGIN.exists() and not OPENCODE_PLUGIN.is_symlink():
        report.add(
            WARN,
            "Cairn's OpenCode plugin is not installed",
            f"{tilde(OPENCODE_PLUGIN)} does not exist.",
            f"python3 {tilde(SCRIPTS / 'install_opencode_plugin.py')} install",
        )
        return

    if not OPENCODE_PLUGIN.is_symlink():
        report.add(
            WARN,
            "OpenCode's Cairn plugin slot is a real file",
            f"{tilde(OPENCODE_PLUGIN)} is not a Cairn-managed symlink. The installer\n"
            "will not replace a file that may belong to you.",
            f"Move it aside, then run: python3 {tilde(SCRIPTS / 'install_opencode_plugin.py')} install",
        )
        return

    try:
        target = OPENCODE_PLUGIN.resolve(strict=True)
    except OSError:
        report.add(
            FAIL,
            "OpenCode plugin is a broken symlink",
            f"{tilde(OPENCODE_PLUGIN)} → {os.readlink(OPENCODE_PLUGIN)}\n"
            "OpenCode cannot load it. This is what a moved checkout looks like.",
            f"python3 {tilde(SCRIPTS / 'install_opencode_plugin.py')} install",
        )
        return

    if target == source.resolve():
        report.add(OK, f"Plugin linked: {tilde(OPENCODE_PLUGIN)} → {tilde(source)}")
    elif in_app_bundle(target):
        report.add(INFO, f"Plugin linked into the installed app bundle: {tilde(target)}")
    else:
        report.add(
            WARN,
            "OpenCode plugin points somewhere else",
            f"linked:    {tilde(target)}\nthis repo: {tilde(source)}\n"
            "Turns are published by that copy, so edits here have no effect.",
        )


def check_deepseek_harness(report: Report) -> None:
    report.section("DeepSeek Harness")
    state = install_deepseek_harness_plugin.status()
    status = state.get("state")
    issue = state.get("issue")
    detail = state.get("message") or ""
    home = state.get("dsh_home")
    if home:
        detail = (detail + "\n" if detail else "") + "DSH_HOME: %s" % tilde(home)

    if status == "not_installed":
        report.add(INFO, "DeepSeek Harness is not installed — skipped", detail)
    elif status == "available":
        report.add(
            WARN,
            "Cairn's Web profile bundle is not connected",
            detail,
            "python3 %s connect deepseek-harness --allow-conversation-access"
            % tilde(SCRIPTS / "cairn_connect.py"),
        )
    elif status == "restart_to_connect":
        report.add(
            WARN,
            "Restart DeepSeek Harness to finish connecting",
            "The Web profile contains Cairn, but no live Cairn marker exists yet."
            + (("\n" + detail) if detail else ""),
        )
    elif status == "connected":
        port = state.get("port")
        report.add(
            OK,
            "Cairn's bundle is live in the Web profile",
            (("Harness Web port: %s\n" % port) if port else "") + detail,
        )
    elif status == "restart_to_disconnect":
        report.add(
            WARN,
            "Restart DeepSeek Harness to finish disconnecting",
            "The profile no longer contains Cairn, but the running process can still publish."
            + (("\n" + detail) if detail else ""),
        )
    else:
        level = FAIL if issue in {"config_invalid", "foreign_plugin"} else WARN
        labels = {
            "cli_missing": "The selected profile exists, but no usable dsh CLI was found",
            "unsupported_version": "This DeepSeek Harness version is unverified",
            "foreign_plugin": "An external bundle uses Cairn's DeepSeek Harness package name",
            "config_invalid": "The DeepSeek Harness Web profile cannot be read safely",
            "partial": "The DeepSeek Harness profile bundle is only partially configured",
        }
        report.add(level, labels.get(issue, "DeepSeek Harness needs attention"), detail)


def check_skills(report: Report) -> None:
    report.section("Deliberate saves (cairn-save skill)")

    targets = {
        "Claude Code": HOME / ".claude" / "skills" / "cairn-save",
        "Codex": HOME / ".codex" / "prompts" / "cairn-save.md",
    }
    installed = False
    for runtime, path in targets.items():
        parent_exists = path.parent.parent.is_dir()
        if path.exists():
            report.add(OK, f"{runtime}: {tilde(path)}")
            installed = True
        elif parent_exists:
            report.add(INFO, f"{runtime}: not installed")

    if not installed and any(p.parent.parent.is_dir() for p in targets.values()):
        report.add(
            INFO,
            "The /cairn-save skill is optional",
            "The Stop hooks capture every turn automatically. This skill is the\n"
            "deliberate counterpart — an agent saving a conclusion on purpose.",
            f"python3 {tilde(SCRIPTS / 'install_agent_skills.py')} install",
        )


def probe(report: Report) -> None:
    """Publish a real note through the real path, then watch it get consumed."""
    report.section("End-to-end probe")

    nonce = uuid.uuid4().hex
    stamp = datetime.now(timezone.utc)
    payload = {
        "id": f"doctor:{nonce}",
        "version": 1,
        "event": "doctor.probe.completed",
        "session_id": "doctor:probe",
        "turn_id": nonce,
        "cwd": str(REPO),
        "title": "Cairn doctor · probe",
        "result": (
            "This note was published by Scripts/cairn_doctor.py --probe to verify "
            "the inbox path end to end. Seeing it means publishing works. You can "
            "dismiss it."
        ),
        "status": "completed",
        "source": "doctor",
        "timestamp": stamp.isoformat().replace("+00:00", "Z"),
    }

    destination = INBOX / f"{stamp.strftime('%Y%m%dT%H%M%S%fZ')}-{nonce}.json"
    try:
        ensure_private_inbox(INBOX)
        temporary = INBOX / f".{nonce}.pending"
        write_private_text(temporary, json.dumps(payload, ensure_ascii=False))
        os.replace(temporary, destination)
    except OSError as error:
        report.add(
            FAIL,
            "Could not publish a probe note",
            f"{error}\nNo producer on this machine can publish either.",
        )
        return

    report.add(OK, f"Published {destination.name}")

    deadline = time.time() + 5
    while time.time() < deadline:
        if not destination.exists():
            report.add(
                OK,
                "Cairn consumed it",
                "A note should now be in the queue, sourced 'Doctor'. The whole\n"
                "path works: publish → atomic rename → poll → decode → display.",
            )
            return
        time.sleep(0.2)

    report.add(
        WARN,
        "Still sitting in the inbox after 5s",
        "Publishing works, but nothing drained it — Cairn is not running, or it\n"
        "cannot read this directory.",
        "open /Applications/Cairn.app, then re-run this probe.",
    )


# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check Cairn's wiring across every supported agent runtime."
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="publish a real test note and verify Cairn consumes it",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit machine-readable results"
    )
    arguments = parser.parse_args()

    report = Report()
    check_environment(report)
    check_app(report)
    check_inbox(report)
    check_codex(report)
    check_claude_code(report)
    check_hermes(report)
    check_openclaw(report)
    check_opencode(report)
    check_deepseek_harness(report)
    check_skills(report)
    if arguments.probe:
        probe(report)

    if arguments.json:
        print(
            json.dumps(
                {
                    "failures": report.failures,
                    "warnings": report.warnings,
                    "sections": [
                        {"title": title, "checks": entries}
                        for title, entries in report.sections
                    ],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print(report.render())

    return 1 if report.failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
