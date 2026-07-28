#!/usr/bin/env python3
"""Install the cairn-save skill for Claude Code and Codex.

Claude Code discovers user-level skills in ``~/.claude/skills/<name>/SKILL.md``
and invokes them by description or as ``/cairn-save``. Codex exposes custom
prompts from ``~/.codex/prompts/<name>.md`` as ``/<name>``. Both wrappers call
the same ``cairn_save.py`` publisher.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Iterable, Optional

from cairn_payload import payload_path

SKILLS = payload_path("AgentSkills")
SOURCES = {
    Path.home() / ".claude" / "skills" / "cairn-save" / "SKILL.md":
        SKILLS / "claude" / "cairn-save" / "SKILL.md",
    Path.home() / ".codex" / "prompts" / "cairn-save.md":
        SKILLS / "codex" / "cairn-save.md",
}
# The runtime whose home directory has to exist for a target to be worth
# writing. Cairn's Connect window installs only where the agent is present;
# the command line stays unconditional.
RUNTIME_HOME = {
    Path.home() / ".claude" / "skills" / "cairn-save" / "SKILL.md": Path.home() / ".claude",
    Path.home() / ".codex" / "prompts" / "cairn-save.md": Path.home() / ".codex",
}


def install(targets: Optional[Iterable[Path]] = None) -> int:
    for target in SOURCES if targets is None else targets:
        source = SOURCES[target]
        if not source.is_file():
            print(f"Missing skill source: {source}", file=sys.stderr)
            return 1
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        print(f"Installed: {target}")
    return 0


def uninstall() -> int:
    for target in SOURCES:
        if target.exists():
            target.unlink()
            print(f"Removed: {target}")
            if target.parent.name == "cairn-save" and not any(target.parent.iterdir()):
                target.parent.rmdir()
    return 0


def main() -> int:
    action = sys.argv[1] if len(sys.argv) == 2 else "install"
    if action not in {"install", "uninstall"}:
        print("Usage: install_agent_skills.py [install|uninstall]", file=sys.stderr)
        return 2
    return install() if action == "install" else uninstall()


if __name__ == "__main__":
    raise SystemExit(main())
