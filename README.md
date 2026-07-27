# Cairn 跡

**Your coding agents finish work while you are looking elsewhere. Cairn leaves a
small stone where each one landed.**

A quiet native macOS companion for completed Codex, Hermes, Claude Code, and
OpenClaw turns. When a turn finishes, Cairn presents the result as a floating
note instead of a system notification or another window competing for your
attention. Click the note and it takes you back to the exact terminal tab the
turn ran in.

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)

- **No Dock icon, no notifications, no focus stealing.** Cairn lives in the menu
  bar and draws its own non-activating panels. It never takes your keyboard.
- **One control.** A small cairn of three river stones: click to expand or
  collapse the queue, drag it somewhere quieter. It remembers where you put it.
- **One note per session.** A later turn from the same session updates its
  existing note instead of stacking another one. Up to 50 sessions, six visible
  at a time.
- **Colour-coded by agent.** Codex teal, Hermes violet, Claude Code terracotta,
  OpenClaw blue.
- **Speaks your Mac's language.** English, Simplified Chinese, and Japanese,
  following the system or per-app setting.
- **寻迹 — follow the trail back.** Clicking a note returns you to where the turn
  ran: the exact Terminal/iTerm2 session, the hosting app window, or — for a
  Codex desktop turn — the exact conversation via `codex://threads/<session_id>`.
- **Local only.** No account, no server, no telemetry. The only network request
  checks GitHub Releases once a day or when you choose **Check for Updates**.

Cairn does not integrate with agents — **it reads a directory**. Anything that
can write a JSON file can leave a note, so supporting a new runtime needs no
change to this app. See [the inbox protocol](docs/inbox-protocol.md).

---

## Install

Download the notarized `.dmg` from
[Releases](https://github.com/quentinzhang/cairn/releases/latest), or build it:

```bash
git clone https://github.com/quentinzhang/cairn.git
cd cairn
./Scripts/build_app.sh
open dist/Cairn.app
```

Requires macOS 14+; building needs Xcode 16+. There are no dependencies to
fetch — only system frameworks and the Python 3 / Node.js standard libraries.

Then connect whichever agents you use. Each installer merges exactly one handler
into your existing config, preserves everything else, and can remove exactly
that handler again with `uninstall`.

```bash
python3 Scripts/install_codex_hook.py install       # Codex CLI and desktop app
python3 Scripts/install_claude_hook.py install      # Claude Code
python3 Scripts/install_openclaw_plugin.py install  # OpenClaw
python3 Scripts/install_hermes_plugin.py            # Hermes
```

Notes per agent:

- **Codex** — run `/hooks` inside Codex and trust the new global hook; Codex
  will not execute an untrusted one.
- **Claude Code** — interrupted turns and API failures do not fire `Stop`, so
  they produce no note.
- **OpenClaw** — the installer asks before enabling conversation access and
  before restarting the managed Gateway; answer both up front with
  `--allow-conversation-access --restart-gateway`. Desktop or unmanaged setups
  may need a manual restart.
- **Hermes** — covers Desktop, CLI, and Gateway turns that produce final
  assistant output.

Complete a turn in any connected agent and a note appears. Use **Check for
Updates** in Cairn's menu at any time — Cairn never downloads or installs an
update without you.

## When something does not arrive

Bridges fail silently on purpose — a completion hook must never break the agent
it runs inside — so there is a tool whose whole job is to explain the silence:

```bash
python3 Scripts/cairn_doctor.py        # add --probe to trace a test note end to end
```

For each runtime you have installed it names the cause and the fix: a hook
pointing at a moved checkout, a plugin linked but not enabled, a malformed
payload in the inbox, a second copy of the app stealing notes. Its output is
safe to paste into an issue: no note bodies, no prompts, no absolute paths
outside the checkout.

## Privacy

Each bridge extracts exactly two things from a completed turn — **the final
assistant message and the most recent user prompt** — and discards the rest. No
reasoning traces, no tool calls, no file contents.

Notes live in two plaintext files in your home directory, mode `0700`,
unencrypted — treat them like your shell history:

```
~/Library/Application Support/Cairn/inbox/            one file per turn, deleted on read
~/Library/Application Support/Cairn/completions.json  the 50 most recent sessions
```

The core queue needs **no** macOS privacy permission. Accessibility and
Automation are optional upgrades that make trail-back precise, granted one app
at a time from **Access** in the menu bar; missing access simply degrades to
activating the app, then to Finder. Full detail, including complete removal:
[SECURITY.md](SECURITY.md).

## Anything else

Write a producer against [`docs/inbox-protocol.md`](docs/inbox-protocol.md) — a
CI pipeline, a long build, another agent runtime. The shortest version is one
line:

```bash
echo "All 214 tests passed." | python3 Scripts/cairn_save.py --source ci --prompt "nightly build"
```

## Saving a note on purpose

```bash
python3 Scripts/install_agent_skills.py install
```

Installs the `cairn-save` skill for Claude Code and Codex. Ask either agent to
"保存到 Cairn", or run `/cairn-save`, and it publishes a deliberate conclusion
note that trails back to where it was saved from — distinct from the automatic
Stop-hook capture.

## Development

```bash
swift build && swift test                     # the app
/usr/bin/python3 Tests/protocol_roundtrip.py  # every bridge, against the protocol
./Scripts/build_app.sh                        # package dist/Cairn.app
```

The protocol tests and Swift tests lock opposite ends of
[`docs/inbox-protocol.md`](docs/inbox-protocol.md); change one and expect the
other to complain. The design system is load-bearing — every colour, radius,
and duration is defined once in
[`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift) and
documented in [`docs/design-system.md`](docs/design-system.md). Regenerate the
Finder icon after intentional brand changes with
`./Scripts/generate_app_icon.sh`.

Releases run every test, sign and notarize locally, tag, and upload the DMG:

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/release.sh --version 0.7.0
```

See [the release guide](docs/releasing.md) for setup and recovery.

## Boundaries

- Covers Codex CLI/App sessions with a trusted user-level hook; Claude Code
  sessions with the user-level `Stop` hook; Hermes and OpenClaw sessions with
  the plugin enabled.
- The app receives the final result only — not streaming progress, not tool logs.
- The 50 most recent sessions are retained locally. No history beyond that, no
  sync between machines.
- macOS 14+ only. The inbox protocol is portable; this app is not.

## Contributing

Bug reports, producers for other runtimes, and trail-back fixes are all welcome.
Start with [CONTRIBUTING.md](CONTRIBUTING.md), and run the doctor before filing
anything.

## License

Apache-2.0 — see [LICENSE](LICENSE).

The code is open. The **name "Cairn", the wordmark 跡, and the stone mark** are
not licensed with it — see [NOTICE](NOTICE). Fork freely; if you ship a modified
build, give it your own name and icon. Describing your tool as compatible with
Cairn, or as implementing the Cairn inbox protocol, is always fine.
