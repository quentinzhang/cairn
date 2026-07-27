# Cairn 跡

**Your coding agents finish work while you are looking elsewhere. Cairn leaves a
small stone where each one landed.**

A quiet native macOS companion for completed Codex, Hermes, Claude Code, and
OpenClaw turns. When a turn finishes, Cairn presents the result as a floating
note instead of a system notification or another window competing for your
attention. Click the note and it takes you back to the exact terminal tab the
turn ran in.

[![CI](https://github.com/everflyzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/everflyzhang/cairn/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)

- **No Dock icon, no notifications, no focus stealing.** Cairn lives in the menu
  bar and draws its own non-activating panels. It never takes your keyboard.
- **One control.** A small cairn of three river stones: click to expand or
  collapse the queue, drag it somewhere quieter. It remembers where you put it
  and stays collapsed by default.
- **One note per session.** A later turn from the same session updates its
  existing note instead of stacking another one. Up to 50 sessions, six visible
  at a time, the rest a scroll away.
- **Colour-coded by agent.** Codex teal, Hermes violet, Claude Code terracotta,
  OpenClaw blue.
- **寻迹 — follow the trail back.** Clicking a note returns you to where the turn
  ran: the exact Apple Terminal tab or iTerm2 session, or the hosting app (VS
  Code, a desktop client) with a best-effort window match. A turn hosted by the
  Codex/ChatGPT desktop app reopens its exact conversation through
  `codex://threads/<session_id>`.
- **Local only.** No account, no server, no telemetry. One request leaves the
  machine: a once-a-day check for a new release, which fails silently.

Cairn does not integrate with agents — **it reads a directory**. Anything that
can write a JSON file can leave a note, so supporting a new runtime needs no
change to this app. See [the inbox protocol](docs/inbox-protocol.md).

---

## Install

Download the notarized `.dmg` from
[Releases](https://github.com/everflyzhang/cairn/releases/latest), or build it:

```bash
git clone https://github.com/everflyzhang/cairn.git
cd cairn
./Scripts/build_app.sh
open dist/Cairn.app
```

Requires macOS 14 (Sonoma) or newer and, to build, a Swift 6 toolchain
(Xcode 16+). There are no dependencies to fetch — Cairn uses only system
frameworks, the Python 3 standard library, and the Node.js standard library.

Then connect whichever agents you use. Each installer merges exactly one handler
into your existing config and can remove exactly that handler again; none of them
rewrites a file you own.

```bash
python3 Scripts/install_codex_hook.py install       # Codex CLI and desktop app
python3 Scripts/install_claude_hook.py install      # Claude Code
python3 Scripts/install_openclaw_plugin.py install  # OpenClaw
python3 Scripts/install_hermes_plugin.py            # Hermes
```

**Codex needs one more step:** run `/hooks` inside Codex and trust the new global
hook. Codex will not execute an untrusted hook, which is a feature Cairn relies
on.

Complete a turn in any connected agent and a note appears.

## When something does not arrive

Bridges fail silently on purpose — a completion hook must never break the agent
it runs inside — so there is a tool whose whole job is to explain the silence:

```bash
python3 Scripts/cairn_doctor.py
```

It checks every runtime you actually have installed, and for each problem it
names the cause and the fix: a hook pointing at a moved checkout, a plugin linked
but not enabled, a malformed payload wedged in the inbox, a second copy of the
app stealing notes. Add `--probe` to publish a real test note and watch it get
consumed end to end.

Its output is designed to be safe to paste into an issue: no note bodies, no
prompts, no absolute paths outside the checkout.

## Privacy

Cairn reads what your agents say, so the specifics matter. Each bridge extracts
exactly two things from a completed turn — **the final assistant message and the
most recent user prompt** — and discards the rest. No reasoning traces, no tool
calls, no tool output, no file contents.

Notes live in two plaintext files in your home directory, mode `0700`:

```
~/Library/Application Support/Cairn/inbox/            one file per turn, deleted on read
~/Library/Application Support/Cairn/completions.json  the 50 most recent sessions
```

They are unencrypted. Treat them like your shell history.

The core queue needs **no** macOS privacy permission. Accessibility and per-app
Automation are optional upgrades that make trail-back precise; they are requested
one application at a time from **Access** in the menu bar, and stay visible and
revocable there. Cairn never raises a permission prompt from an ordinary note
click — missing access simply degrades to activating the app, then to Finder.

Full detail, including how to remove Cairn completely: [SECURITY.md](SECURITY.md).

---

## Connecting each agent

### Codex

```bash
python3 Scripts/install_codex_hook.py install
```

Adds Cairn's `Stop` handler to `~/.codex/hooks.json`, preserving existing
handlers. Trust it with `/hooks` inside Codex.

Codex documents `Stop` as a turn lifecycle event and passes a `transcript_path`,
but describes the transcript format as unstable. Cairn therefore keeps transcript
extraction in the bridge script, accepts both current message shapes, and never
makes a Codex turn fail when the app is closed.

```bash
python3 Scripts/install_codex_hook.py uninstall
```

### Claude Code

```bash
python3 Scripts/install_claude_hook.py install
```

Adds one command handler to the user-level `Stop` event in
`~/.claude/settings.json`, preserving every existing setting and hook. Claude
Code provides the final reply through `last_assistant_message`; the transcript is
read only to recover the latest user prompt, or as a compatibility fallback.
Interrupted turns and API failures do not fire `Stop`, so they produce no note.

```bash
python3 Scripts/install_claude_hook.py uninstall
```

### OpenClaw

```bash
python3 Scripts/install_openclaw_plugin.py install
```

Registers a source-backed plugin on OpenClaw's `agent_end` hook. The installer
explains and asks before enabling the conversation access that newer OpenClaw
versions require, and asks again before restarting the managed Gateway. Cairn
keeps only the last user prompt and the final reply. Only successful turns with
final assistant text produce a note.

For a non-interactive install:

```bash
python3 Scripts/install_openclaw_plugin.py install \
  --allow-conversation-access --restart-gateway
```

OpenClaw Desktop or an unmanaged Gateway needs a manual restart if the installer
asks. To remove: `python3 Scripts/install_openclaw_plugin.py uninstall`.

### Hermes

```bash
python3 Scripts/install_hermes_plugin.py
```

Creates a source-backed plugin at `~/.hermes/plugins/cairn`, enables it through
`hermes plugins enable cairn`, and registers Hermes's `post_llm_call` lifecycle
hook. Covers Desktop, CLI, and Gateway turns that produce final assistant
output; interrupted or failed turns produce no note.

### Anything else

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

Installs the `cairn-save` skill for Claude Code (`~/.claude/skills/`) and Codex
(`~/.codex/prompts/`). Ask either agent to "保存到 Cairn", or run `/cairn-save`,
and it publishes a deliberate conclusion note — distinct from the automatic
Stop-hook capture. Repeated saves from the same directory update a single note,
and the saved note carries a locator, so clicking it trails back to where it was
saved from.

## Development

```bash
swift build && swift test                     # the app
/usr/bin/python3 Tests/protocol_roundtrip.py  # every bridge, against the protocol
./Scripts/build_app.sh                        # package dist/Cairn.app
```

The protocol tests run every bundled producer against
[`docs/inbox-protocol.md`](docs/inbox-protocol.md) in a temporary HOME and check
both the payload contract and the atomic publishing contract. The Swift tests
lock the consumer end of the same document. If you change one, expect the other
to complain.

The design system is load-bearing rather than decorative — Cairn has no window
chrome to inherit style from, so every colour, radius, duration, and dimension
is defined once in [`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift)
and documented in [`docs/design-system.md`](docs/design-system.md).

The Finder icon is generated from Cairn's stone mark; regenerate it after
intentional brand changes with `./Scripts/generate_app_icon.sh`.

### Packaging a release

Store App Store Connect credentials in a `notarytool` keychain profile, then:

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/package_release.sh
```

Hardened runtime signing, notarization and stapling of both the app and the DMG,
and Gatekeeper validation before it reports success.

## Boundaries

- Covers local Codex CLI/App sessions with a trusted user-level hook; Claude Code
  sessions with the user-level `Stop` hook; Hermes Desktop/CLI/Gateway sessions
  with the plugin enabled; and OpenClaw Agent/Gateway sessions with the plugin
  enabled.
- The app receives the final result only — not streaming progress, not tool logs.
- The 50 most recent sessions are retained locally. There is no history beyond
  that, and no sync between machines.
- macOS 14+ only. The inbox protocol is portable; this app is not.

## Contributing

Bug reports, producers for other runtimes, and trail-back fixes are all welcome.
Start with [CONTRIBUTING.md](CONTRIBUTING.md), and run the doctor before filing
anything.

## License

Apache-2.0 — see [LICENSE](LICENSE).

The code is open. The **name "Cairn", the wordmark 跡, and the stone mark** are
not licensed with it — see [NOTICE](NOTICE). Fork freely; if you ship a modified
build, give it your own name and icon so users can tell it apart from an official
release. Describing your tool as compatible with Cairn, or as implementing the
Cairn inbox protocol, is always fine.
