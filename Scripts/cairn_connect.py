#!/usr/bin/env python3
"""One machine-readable door onto every Cairn bridge, for the app to drive.

Connecting an agent used to mean finding a checkout and typing a command per
runtime, which a downloaded `.app` has no way to offer. This module is what
Cairn's Connect window drives instead: it detects which agents exist on this
Mac, reports exactly how each one is wired, and connects or disconnects one on
request — without asking a single question, because a GUI has already asked
them.

    python3 cairn_connect.py status                    # human-readable
    python3 cairn_connect.py status --json             # what the app reads
    python3 cairn_connect.py connect claude
    python3 cairn_connect.py connect openclaw --allow-conversation-access
    python3 cairn_connect.py disconnect codex

The per-runtime installers stay the source of truth for *what* gets written;
this only sequences them and names the resulting state, so the window and the
command line can never disagree about what "connected" means.

Two things it deliberately does that the individual installers do not:

* **Prunes before installing.** A hook left behind by a moved or deleted
  checkout is removed, then rewritten against this copy. Clicking Connect on a
  broken row has to repair it, not stack a second handler beside it.
* **Rebuilds PATH.** A GUI app inherits launchd's four-entry PATH, so `hermes`
  and `openclaw` are invisible to it. Their own CLIs are the only supported way
  to enable a plugin, so the login shell's PATH is recovered first.

Every state is reported as a code, never a sentence: the app renders them in
the user's language, and English prose in a JSON payload cannot be localized.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import install_agent_skills
import install_claude_hook
import install_codex_hook
import install_hermes_plugin
import install_opencode_plugin
import install_openclaw_plugin

HOME = Path.home()
CODEX_HOME = HOME / ".codex"
CLAUDE_HOME = HOME / ".claude"
HERMES_HOME = HOME / ".hermes"
OPENCODE_HOME = HOME / ".config" / "opencode"

RUNTIMES = ("codex", "claude", "openclaw", "opencode", "hermes", "skills")

NOT_INSTALLED = "not_installed"
AVAILABLE = "available"
CONNECTED = "connected"
ATTENTION = "attention"

SCHEMA = 1

# Issue codes. The app maps each to a localized caption; anything unmapped
# degrades to the free-text `message`, so adding one here is never breaking.
CONFIG_INVALID = "config_invalid"
SCRIPT_MISSING = "script_missing"
DUPLICATE = "duplicate"
OTHER_SOURCE = "other_source"
DISABLED = "disabled"
CLI_MISSING = "cli_missing"
FOREIGN_PLUGIN = "foreign_plugin"
BROKEN_LINK = "broken_link"
PARTIAL = "partial"
NO_CONSENT = "no_consent"
NEEDS_CONSENT = "needs_consent"
PLUGIN_MISSING = "plugin_missing"

# Follow-up codes: true, useful things Cairn cannot do on the user's behalf.
CODEX_TRUST = "codex_trust"
OPENCLAW_RESTART = "openclaw_restart"
HERMES_ENABLE = "hermes_enable"
HERMES_RESTART = "hermes_restart"


# --------------------------------------------------------------------------
# environment
# --------------------------------------------------------------------------


_PATH_SENTINEL = "__CAIRN_PATH__"


def _login_shell_path() -> str:
    """The PATH a terminal would have, recovered from the user's login shell.

    Cairn's window runs under launchd, whose PATH is four system directories —
    no Homebrew, no nvm, no volta. Anything a user installed for their agents
    lives outside it. The sentinel is there because a login profile is allowed
    to print whatever it likes before we get a word in.
    """
    shell = os.environ.get("SHELL") or "/bin/zsh"
    command = 'printf "\\n' + _PATH_SENTINEL + '%s\\n" "$PATH"'
    try:
        finished = subprocess.run(
            [shell, "-lc", command],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in reversed(finished.stdout.splitlines()):
        if line.startswith(_PATH_SENTINEL):
            return line[len(_PATH_SENTINEL) :]
    return ""


def enriched_path() -> str:
    parts: List[str] = []

    def add(value: Any) -> None:
        text = str(value)
        if not text or text in parts:
            return
        try:
            if Path(text).is_dir():
                parts.append(text)
        except OSError:
            pass

    for entry in os.environ.get("PATH", "").split(os.pathsep):
        add(entry)
    for entry in _login_shell_path().split(os.pathsep):
        add(entry)
    for entry in (
        "/opt/homebrew/bin",
        "/usr/local/bin",
        # pnpm's default PNPM_HOME. It is exported from ~/.zshrc, which a
        # login (non-interactive) shell never reads — so the recovered PATH
        # misses it exactly when a GUI app is the one asking.
        HOME / "Library" / "pnpm",
        HOME / ".local" / "bin",
        HOME / ".bun" / "bin",
        HOME / ".volta" / "bin",
        HOME / ".deno" / "bin",
        HOME / ".npm-global" / "bin",
        HOME / "bin",
    ):
        add(entry)
    nvm = HOME / ".nvm" / "versions" / "node"
    if nvm.is_dir():
        try:
            for version in sorted(nvm.iterdir(), reverse=True):
                add(version / "bin")
        except OSError:
            pass
    return os.pathsep.join(parts)


def prepare_environment() -> None:
    os.environ["PATH"] = enriched_path()


def which(executable: str) -> Optional[str]:
    return shutil.which(executable)


# --------------------------------------------------------------------------
# helpers
#
# Deliberately duplicated from cairn_doctor rather than imported: the app
# depends on this module, and the app must not depend on a diagnostic tool
# that a user is free to delete.
# --------------------------------------------------------------------------


def tilde(path: Any) -> str:
    text = str(path)
    home = str(HOME)
    if text == home:
        return "~"
    if text.startswith(home + os.sep):
        return "~" + text[len(home) :]
    return text


def read_json(path: Path) -> Tuple[Any, Optional[str]]:
    """Return (parsed, error). A missing file is (None, None), not an error."""
    if not path.exists():
        return None, None
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except json.JSONDecodeError as error:
        return None, "invalid JSON at line %d: %s" % (error.lineno, error.msg)
    except OSError as error:
        return None, str(error)


def stop_handlers(config: Any) -> List[Dict[str, Any]]:
    hooks = config.get("hooks") if isinstance(config, dict) else None
    stop = hooks.get("Stop") if isinstance(hooks, dict) else None
    if not isinstance(stop, list):
        return []
    handlers: List[Dict[str, Any]] = []
    for group in stop:
        entries = group.get("hooks") if isinstance(group, dict) else None
        if isinstance(entries, list):
            handlers.extend(h for h in entries if isinstance(h, dict))
    return handlers


def referenced_scripts(handler: Dict[str, Any]) -> List[Path]:
    blob = " ".join(
        [str(handler.get("command", ""))]
        + [str(a) for a in handler.get("args", []) if isinstance(a, (str, int))]
    )
    return [Path(m) for m in re.findall(r"/[^\s\"']+\.py", blob)]


def mentions(handler: Dict[str, Any], script_name: str) -> bool:
    return any(path.name == script_name for path in referenced_scripts(handler))


def prune_stop_handlers(config: Dict[str, Any], script_name: str) -> int:
    """Remove every Cairn handler for `script_name`, whatever copy it points at.

    Returns how many were dropped. This is what makes Connect idempotent and
    self-repairing: whatever was there — a stale path, three duplicates — is
    replaced by exactly one handler aimed at this installation.
    """
    hooks = config.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    stop = hooks.get("Stop")
    if not isinstance(stop, list):
        return 0

    removed = 0
    retained: List[Any] = []
    for group in stop:
        if not isinstance(group, dict):
            retained.append(group)
            continue
        handlers = group.get("hooks")
        if not isinstance(handlers, list):
            retained.append(group)
            continue
        kept = [
            handler
            for handler in handlers
            if not (isinstance(handler, dict) and mentions(handler, script_name))
        ]
        removed += len(handlers) - len(kept)
        if kept:
            updated = dict(group)
            updated["hooks"] = kept
            retained.append(updated)

    if retained:
        hooks["Stop"] = retained
    else:
        hooks.pop("Stop", None)
    return removed


def entry(
    identifier: str,
    state: str,
    issue: Optional[str] = None,
    message: Optional[str] = None,
    consent: bool = False,
    follow_up: Optional[str] = None,
) -> Dict[str, Any]:
    return {
        "id": identifier,
        "state": state,
        "issue": issue,
        "message": message,
        "consent": consent,
        "follow_up": follow_up,
    }


def hook_state(
    identifier: str,
    config: Any,
    script_name: str,
    expected: Path,
) -> Dict[str, Any]:
    """Classify a Codex/Claude-shaped Stop hook tree."""
    ours = [h for h in stop_handlers(config) if mentions(h, script_name)]
    if not ours:
        return entry(identifier, AVAILABLE)

    scripts = [p for handler in ours for p in referenced_scripts(handler) if p.name == script_name]
    missing = [p for p in scripts if not p.exists()]
    if missing:
        return entry(
            identifier,
            ATTENTION,
            SCRIPT_MISSING,
            "\n".join(tilde(path) for path in sorted(set(missing))),
        )
    if len(ours) > 1:
        return entry(identifier, ATTENTION, DUPLICATE, str(len(ours)))
    if any(path.resolve() != expected.resolve() for path in scripts):
        return entry(
            identifier,
            CONNECTED,
            OTHER_SOURCE,
            "\n".join(tilde(path) for path in sorted(set(scripts))),
        )
    return entry(identifier, CONNECTED)


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------


def codex_status() -> Dict[str, Any]:
    if not CODEX_HOME.is_dir() and not which("codex"):
        return entry("codex", NOT_INSTALLED)
    config, error = read_json(install_codex_hook.HOOKS_FILE)
    if error:
        return entry("codex", ATTENTION, CONFIG_INVALID, error)
    if config is None:
        return entry("codex", AVAILABLE)
    return hook_state("codex", config, "cairn_codex_hook.py", install_codex_hook.SCRIPT)


def claude_status() -> Dict[str, Any]:
    if not CLAUDE_HOME.is_dir() and not which("claude"):
        return entry("claude", NOT_INSTALLED)
    config, error = read_json(install_claude_hook.SETTINGS_FILE)
    if error:
        return entry("claude", ATTENTION, CONFIG_INVALID, error)
    if config is None:
        return entry("claude", AVAILABLE)
    return hook_state("claude", config, "cairn_claude_hook.py", install_claude_hook.SCRIPT)


def hermes_status() -> Dict[str, Any]:
    target = install_hermes_plugin.TARGET
    source = install_hermes_plugin.SOURCE
    if not HERMES_HOME.is_dir() and not which("hermes"):
        return entry("hermes", NOT_INSTALLED)

    if target.is_symlink():
        try:
            linked = target.resolve(strict=True)
        except OSError:
            return entry("hermes", ATTENTION, BROKEN_LINK, tilde(target))
        if linked != source.resolve():
            return entry("hermes", CONNECTED, OTHER_SOURCE, tilde(linked))
        return entry("hermes", CONNECTED)
    if target.exists():
        return entry("hermes", ATTENTION, FOREIGN_PLUGIN, tilde(target))
    if not which("hermes"):
        return entry("hermes", AVAILABLE, CLI_MISSING)
    return entry("hermes", AVAILABLE)


def opencode_status() -> Dict[str, Any]:
    target = install_opencode_plugin.TARGET
    source = install_opencode_plugin.SOURCE
    if not OPENCODE_HOME.is_dir() and not which("opencode"):
        return entry("opencode", NOT_INSTALLED)
    if target.is_symlink():
        try:
            linked = target.resolve(strict=True)
        except OSError:
            return entry("opencode", ATTENTION, BROKEN_LINK, tilde(target))
        if linked != source.resolve():
            return entry("opencode", CONNECTED, OTHER_SOURCE, tilde(linked))
        return entry("opencode", CONNECTED)
    if target.exists():
        return entry("opencode", ATTENTION, FOREIGN_PLUGIN, tilde(target))
    issue = None if which("opencode") else CLI_MISSING
    return entry("opencode", AVAILABLE, issue)


def openclaw_load_paths(config: Dict[str, Any]) -> List[str]:
    """Every directory OpenClaw is configured to load the Cairn plugin from.

    Reported verbatim when it is not this installation's copy: "somewhere else"
    is not an answer a person can act on, and the path is the whole answer.
    """
    plugins = config.get("plugins")
    if not isinstance(plugins, dict):
        return []
    paths: List[str] = []
    installs = plugins.get("installs")
    install = installs.get(install_openclaw_plugin.PLUGIN_ID) if isinstance(installs, dict) else None
    if isinstance(install, dict):
        for key in ("sourcePath", "installPath"):
            value = install.get(key)
            if isinstance(value, str):
                paths.append(value)
    load = plugins.get("load")
    entries = load.get("paths") if isinstance(load, dict) else None
    if isinstance(entries, list):
        paths.extend(value for value in entries if isinstance(value, str))
    resolved = sorted({str(Path(value).expanduser()) for value in paths})
    return [tilde(value) for value in resolved]


def openclaw_status() -> Dict[str, Any]:
    config_file = install_openclaw_plugin.CONFIG_FILE
    if not config_file.parent.is_dir() and not which("openclaw"):
        return entry("openclaw", NOT_INSTALLED)

    config, error = read_json(config_file)
    if error:
        return entry("openclaw", ATTENTION, CONFIG_INVALID, error, consent=True)
    config = config if isinstance(config, dict) else {}
    granted = install_openclaw_plugin.conversation_access_enabled(config)

    plugins = config.get("plugins")
    entries = plugins.get("entries") if isinstance(plugins, dict) else None
    plugin = entries.get("cairn") if isinstance(entries, dict) else None
    if not isinstance(plugin, dict):
        issue = None if which("openclaw") else CLI_MISSING
        return entry("openclaw", AVAILABLE, issue, consent=not granted)
    if plugin.get("enabled") is not True:
        return entry("openclaw", ATTENTION, DISABLED, consent=not granted)

    linked = install_openclaw_plugin.is_linked_to_source(config)
    if not linked:
        configured = openclaw_load_paths(config)
        # A path OpenClaw cannot read is a broken connection, not a remote one.
        # Enabled-but-pointing-nowhere is the exact shape of an app that was
        # moved or deleted after it was connected, and it publishes nothing.
        missing = [
            value
            for value in configured
            if not Path(value.replace("~", str(HOME), 1)).exists()
        ]
        if missing:
            return entry(
                "openclaw",
                ATTENTION,
                PLUGIN_MISSING,
                "\n".join(missing),
                consent=not granted,
            )
        return entry(
            "openclaw",
            CONNECTED,
            OTHER_SOURCE,
            "\n".join(configured),
            consent=not granted,
        )
    if not granted:
        return entry("openclaw", CONNECTED, NO_CONSENT, consent=True)
    return entry("openclaw", CONNECTED)


def skills_targets() -> List[Path]:
    return [
        target
        for target, home in install_agent_skills.RUNTIME_HOME.items()
        if home.is_dir()
    ]


def skills_status() -> Dict[str, Any]:
    relevant = skills_targets()
    if not relevant:
        return entry("skills", NOT_INSTALLED)
    present = [target for target in relevant if target.exists()]
    if not present:
        return entry("skills", AVAILABLE)
    if len(present) < len(relevant):
        return entry(
            "skills",
            ATTENTION,
            PARTIAL,
            "\n".join(tilde(t) for t in relevant if not t.exists()),
        )
    return entry("skills", CONNECTED)


STATUS: Dict[str, Callable[[], Dict[str, Any]]] = {
    "codex": codex_status,
    "claude": claude_status,
    "openclaw": openclaw_status,
    "opencode": opencode_status,
    "hermes": hermes_status,
    "skills": skills_status,
}


def status_report() -> Dict[str, Any]:
    runtimes = []
    for identifier in RUNTIMES:
        try:
            runtimes.append(STATUS[identifier]())
        except Exception as error:  # a broken probe must not hide the others
            runtimes.append(entry(identifier, ATTENTION, message=str(error)))
    return {"schema": SCHEMA, "runtimes": runtimes}


# --------------------------------------------------------------------------
# connect / disconnect
# --------------------------------------------------------------------------


def result(identifier: str, ok: bool, message: str = "", follow_up: Optional[str] = None) -> Dict[str, Any]:
    payload = {"id": identifier, "ok": ok, "message": message, "follow_up": follow_up}
    payload["state"] = STATUS[identifier]()
    return payload


def connect_codex() -> Dict[str, Any]:
    config = install_codex_hook.load()
    pruned = prune_stop_handlers(config, "cairn_codex_hook.py")
    install_codex_hook.install(config)
    install_codex_hook.write(config)
    return result(
        "codex",
        True,
        "Stop hook written to %s" % tilde(install_codex_hook.HOOKS_FILE)
        + (" (%d stale handler(s) removed)" % pruned if pruned else ""),
        follow_up=CODEX_TRUST,
    )


def disconnect_codex() -> Dict[str, Any]:
    config = install_codex_hook.load()
    removed = prune_stop_handlers(config, "cairn_codex_hook.py")
    if removed:
        install_codex_hook.write(config)
    return result("codex", True, "%d handler(s) removed" % removed)


def connect_claude() -> Dict[str, Any]:
    config = install_claude_hook.load()
    pruned = prune_stop_handlers(config, "cairn_claude_hook.py")
    install_claude_hook.install(config)
    install_claude_hook.write(config)
    return result(
        "claude",
        True,
        "Stop hook written to %s" % tilde(install_claude_hook.SETTINGS_FILE)
        + (" (%d stale handler(s) removed)" % pruned if pruned else ""),
    )


def disconnect_claude() -> Dict[str, Any]:
    config = install_claude_hook.load()
    removed = prune_stop_handlers(config, "cairn_claude_hook.py")
    if removed:
        install_claude_hook.write(config)
    return result("claude", True, "%d handler(s) removed" % removed)


def connect_hermes() -> Dict[str, Any]:
    if not install_hermes_plugin.valid_source():
        return result("hermes", False, "Missing plugin payload: %s" % tilde(install_hermes_plugin.SOURCE))
    install_hermes_plugin.relink()
    executable = which("hermes")
    if not executable:
        # The link is real and correct; only the enable step is missing, and
        # only Hermes itself can perform it.
        return result(
            "hermes",
            True,
            "Linked %s, but the hermes CLI is not on PATH" % tilde(install_hermes_plugin.TARGET),
            follow_up=HERMES_ENABLE,
        )
    finished = subprocess.run(
        [executable, "plugins", "enable", "cairn"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if finished.returncode != 0:
        return result("hermes", False, (finished.stdout + finished.stderr).strip())
    return result("hermes", True, "Plugin linked and enabled", follow_up=HERMES_RESTART)


def disconnect_hermes() -> Dict[str, Any]:
    notes = []
    executable = which("hermes")
    if executable:
        finished = subprocess.run(
            [executable, "plugins", "disable", "cairn"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if finished.returncode != 0:
            notes.append((finished.stdout + finished.stderr).strip())
    removed = install_hermes_plugin.unlink()
    notes.insert(0, "Plugin unlinked" if removed else "Nothing to remove")
    # Disconnecting is complete on disk and still not complete in memory: a
    # Hermes gateway or session that is already running imported the plugin at
    # startup and keeps calling it. Nothing here can unload it.
    return result("hermes", True, "\n".join(notes), follow_up=HERMES_RESTART)


def connect_opencode() -> Dict[str, Any]:
    if not install_opencode_plugin.valid_source():
        return result(
            "opencode", False,
            "Missing plugin payload: %s" % tilde(install_opencode_plugin.SOURCE),
        )
    install_opencode_plugin.relink()
    if not which("opencode"):
        return result(
            "opencode", True,
            "Linked %s, but the opencode CLI is not on PATH" % tilde(install_opencode_plugin.TARGET),
        )
    return result("opencode", True, "Plugin linked; restart OpenCode to load it")


def disconnect_opencode() -> Dict[str, Any]:
    removed = install_opencode_plugin.unlink()
    return result("opencode", True, "Plugin unlinked" if removed else "Nothing to remove")


def connect_openclaw(allow_conversation_access: bool) -> Dict[str, Any]:
    if not (install_openclaw_plugin.SOURCE / "openclaw.plugin.json").is_file():
        return result(
            "openclaw",
            False,
            "Missing plugin payload: %s" % tilde(install_openclaw_plugin.SOURCE),
        )
    # Re-aim the config before touching the CLI. OpenClaw validates its whole
    # config on startup and refuses every `plugins` command while a load path
    # points at nothing — which is exactly the state a moved or deleted Cairn
    # leaves behind. Repairing through the CLI first is therefore impossible;
    # this is a plain JSON edit of the one key at fault.
    repaired = install_openclaw_plugin.load_config()
    if install_openclaw_plugin.prefer_current_plugin_source(repaired):
        install_openclaw_plugin.write_config(repaired)

    executable, environment = install_openclaw_plugin.openclaw_environment()
    already = install_openclaw_plugin.conversation_access_enabled(
        install_openclaw_plugin.load_config()
    )
    # Probing the CLI schema costs a whole Node start-up. A config that already
    # grants conversation access has answered the question.
    supported = already or install_openclaw_plugin.supports_conversation_access(
        executable, environment
    )
    allowed = already or allow_conversation_access
    if supported and not allowed:
        return {
            "id": "openclaw",
            "ok": False,
            "message": "",
            "follow_up": None,
            "issue": NEEDS_CONSENT,
            "state": openclaw_status(),
        }
    install_openclaw_plugin.install(
        executable, environment, raw_access_supported=supported and allowed
    )
    install_openclaw_plugin.restart_gateway(executable, environment)
    return result("openclaw", True, "Plugin enabled", follow_up=OPENCLAW_RESTART)


def disconnect_openclaw() -> Dict[str, Any]:
    executable, environment = install_openclaw_plugin.openclaw_environment()
    install_openclaw_plugin.uninstall(executable, environment)
    install_openclaw_plugin.restart_gateway(executable, environment)
    return result("openclaw", True, "Plugin removed", follow_up=OPENCLAW_RESTART)


def connect_skills() -> Dict[str, Any]:
    targets = skills_targets()
    if not targets:
        return result("skills", False, "Neither Claude Code nor Codex is installed")
    code = install_agent_skills.install(targets)
    return result("skills", code == 0, "%d skill file(s) installed" % len(targets))


def disconnect_skills() -> Dict[str, Any]:
    install_agent_skills.uninstall()
    return result("skills", True, "Skill files removed")


CONNECT: Dict[str, Callable[..., Dict[str, Any]]] = {
    "codex": connect_codex,
    "claude": connect_claude,
    "openclaw": connect_openclaw,
    "opencode": connect_opencode,
    "hermes": connect_hermes,
    "skills": connect_skills,
}

DISCONNECT: Dict[str, Callable[[], Dict[str, Any]]] = {
    "codex": disconnect_codex,
    "claude": disconnect_claude,
    "openclaw": disconnect_openclaw,
    "opencode": disconnect_opencode,
    "hermes": disconnect_hermes,
    "skills": disconnect_skills,
}


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------


NAMES = {
    "codex": "Codex",
    "claude": "Claude Code",
    "openclaw": "OpenClaw",
    "opencode": "OpenCode",
    "hermes": "Hermes",
    "skills": "/cairn-save skill",
}

GLYPH = {CONNECTED: "✓", AVAILABLE: "○", ATTENTION: "!", NOT_INSTALLED: "·"}


def render_status(report: Dict[str, Any]) -> str:
    lines = [""]
    for item in report["runtimes"]:
        line = "  %s %-18s %s" % (
            GLYPH.get(item["state"], "?"),
            NAMES.get(item["id"], item["id"]),
            item["state"].replace("_", " "),
        )
        if item.get("issue"):
            line += " (%s)" % item["issue"]
        lines.append(line)
        if item.get("message"):
            for detail in str(item["message"]).splitlines():
                lines.append("      " + detail)
    lines.append("")
    lines.append("  connect:    python3 %s connect <id>" % Path(__file__).name)
    lines.append("  disconnect: python3 %s disconnect <id>" % Path(__file__).name)
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Connect coding agents to Cairn")
    parser.add_argument("action", choices=("status", "connect", "disconnect"))
    parser.add_argument("runtime", nargs="?", choices=RUNTIMES)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument(
        "--allow-conversation-access",
        action="store_true",
        help="OpenClaw only: allow Cairn to read the final conversation",
    )
    return parser.parse_args()


def reserve_stdout() -> int:
    """Hand file descriptor 1 to the diagnostics and keep a private copy.

    Connecting runs other people's programs — `openclaw plugins install`,
    `hermes plugins enable` — and they write to stdout with no way to ask them
    not to. In `--json` mode stdout is a protocol, so it is moved out of reach
    before anything else runs and only the payload is written back to it.
    """
    sys.stdout.flush()
    saved = os.dup(1)
    os.dup2(2, 1)
    return saved


def emit(payload: Dict[str, Any], stdout_fd: int) -> None:
    os.write(stdout_fd, json.dumps(payload).encode("utf-8"))
    os.close(stdout_fd)


def main() -> int:
    args = parse_args()
    stdout_fd = reserve_stdout() if args.json else -1
    prepare_environment()

    if args.action == "status":
        report = status_report()
        if args.json:
            emit(report, stdout_fd)
        else:
            print(render_status(report))
        return 0

    if not args.runtime:
        print("A runtime is required: %s" % ", ".join(RUNTIMES), file=sys.stderr)
        return 2

    try:
        if args.action == "connect":
            action = CONNECT[args.runtime]
            payload = (
                action(args.allow_conversation_access)
                if args.runtime == "openclaw"
                else action()
            )
        else:
            payload = DISCONNECT[args.runtime]()
    except Exception as error:  # every failure is reportable, none is fatal
        payload = {
            "id": args.runtime,
            "ok": False,
            "message": str(error),
            "follow_up": None,
            "state": STATUS[args.runtime](),
        }

    if args.json:
        emit(payload, stdout_fd)
    else:
        print(("✓ " if payload["ok"] else "✗ ") + (payload["message"] or payload["state"]["state"]))
    return 0 if payload["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
