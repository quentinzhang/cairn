<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/cairn-mark-dark.svg">
  <img src="docs/assets/cairn-mark.svg" width="72" alt="">
</picture>

# Cairn

**A trail for every task.**

Your coding agents finish while you are looking elsewhere.<br>
Cairn leaves a small note where each one landed — click it to go back.

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)

### [⬇︎ Download for macOS](https://github.com/quentinzhang/cairn/releases/latest)

</div>

---

## For users

### What it does

When your coding agent — say **Codex** or **Claude Code** — finishes a turn, a
note settles beside a small stack of three river stones on your desktop.

- **Never interrupts.** No Dock icon, no system notification, no window that
  takes your keyboard. Cairn reports; it never demands a reply.
- **Everything stacks.** One note per session, coloured by agent, gathered into
  one stack per agent per project. Fifty sessions are remembered.
- **Follows the trail back.** Click a note and Cairn returns you to where the
  turn ran — the exact Terminal/iTerm2 tab, the app window, or the Codex
  conversation itself.
- **Yours alone.** No account, no server, no telemetry. Everything stays on
  this Mac.

### Install

1. Download the notarized `.dmg` from
   [Releases](https://github.com/quentinzhang/cairn/releases/latest) and drag
   **Cairn** into Applications.
2. Open it. On first launch Cairn finds the coding agents installed on this Mac
   and lists them — today **Codex**, **Claude Code**, **OpenClaw**,
   **OpenCode**, and **Hermes**.
3. Click **Connect** on each one you use, then **Start Using Cairn**.

That is the whole setup — **no terminal, no scripts, no config files to edit.**
Connecting writes exactly one handler into that agent's own config and leaves
everything else untouched; **Disconnect** removes exactly that handler again. A
row marked *needs attention* is repaired by the same click. Reopen the window
any time from **Apps** in Cairn's menu.

Requires macOS 14 or later.

A few agents need one more step of their own, which Cairn spells out in the row
right after you connect:

| Agent | After connecting |
| --- | --- |
| **Codex** | Run `/hooks` inside Codex once and trust the Cairn handler — Codex will not execute one it does not trust. |
| **Claude Code** | Nothing. (Interrupted turns and API failures never fire `Stop`, so they leave no note.) |
| **OpenClaw** | Cairn asks once whether it may read the final message, then restarts the managed Gateway for you. |
| **OpenCode** | Restart OpenCode if it was already running. |
| **Hermes** | Restart Hermes if it was already running. |

### Everyday use

- **The stones** sit on your desktop: click to expand or collapse the queue,
  drag them somewhere quieter. They remember where you put them.
- **⌃⌥⌘C** shows and hides the notes from any app — the default shortcut, and
  yours to change in Settings.
- **Clicking a note** follows the trail back.
- **Notes stay organised** — coloured by agent, and stacked into one pile per
  agent per project.

### Boundaries

- Cairn receives the final result only — not streaming progress, not tool logs.
- The 50 most recent sessions are kept locally. No history beyond that, no sync
  between machines.
- macOS 14+ only.

## Develop from source

All commands below run from the repository checkout. They do not depend on
scripts inside an installed copy of Cairn.

### Build and run

```bash
git clone https://github.com/quentinzhang/cairn.git && cd cairn
swift build && swift test                     # compile and test the Swift target
/usr/bin/python3 Tests/protocol_roundtrip.py  # test every bridge against the protocol
./Scripts/build_app.sh                        # assemble and sign dist/Cairn.app
open dist/Cairn.app                           # run the complete local App
```

Building needs Xcode 16+. There are no dependencies to fetch — only system
frameworks and the Python 3 / Node.js standard libraries.

`swift build` produces the Swift executable and SwiftPM resources under
`.build/`; it does not assemble a macOS App. `Scripts/build_app.sh` performs
the release build, copies every bridge and runtime plugin — including
OpenCode — into `dist/Cairn.app`, adds the App resources and entitlements, and
signs the finished bundle.

### Diagnose missing notes

Bridges fail silently on purpose — a completion hook must never break the agent
it runs inside — so the source tree includes one tool to explain the silence:

```bash
python3 Scripts/cairn_doctor.py
```

For every runtime you have installed it names the cause and the fix: a hook
pointing at something that moved, a plugin linked but not enabled, a malformed
payload in the inbox, a second copy of the app stealing notes. Add `--probe` to
trace a test note end to end. The output is safe to paste into an issue — no
note bodies, no prompts, no paths from outside the checkout.

### Privacy and storage

Each bridge keeps exactly two things from a finished turn — **the final
assistant message and the most recent user prompt** — and discards the rest. No
reasoning traces, no tool calls, no file contents.

Notes live in two plaintext files in your home directory, mode `0700` — treat
them like your shell history:

```
~/Library/Application Support/Cairn/inbox/            one file per turn, deleted on read
~/Library/Application Support/Cairn/completions.json  the 50 most recent sessions
```

The queue needs **no** macOS privacy permission. Accessibility and Automation
are optional upgrades that make the trail back precise, granted one app at a
time under **Access**; without them a click simply degrades to activating the
app, then to Finder. The only network request checks GitHub Releases once a
day. Full detail, including complete removal: [SECURITY.md](SECURITY.md).

### Extend the inbox protocol

Cairn does not integrate with agents — **it reads a directory**. A CI pipeline,
a long build, or another agent runtime can write a producer against
[`docs/inbox-protocol.md`](docs/inbox-protocol.md). The shortest source-tree
example is one line:

```bash
echo "All 214 tests passed." | python3 Scripts/cairn_save.py \
  --source ci --prompt "nightly build"
```

### Connection scripts and deliberate saves

Everything the Connect window does is available from the checkout:

```bash
python3 Scripts/cairn_connect.py status              # what is detected, what is wired
python3 Scripts/cairn_connect.py connect claude      # codex · claude · openclaw · opencode · hermes · skills
python3 Scripts/cairn_connect.py disconnect claude
```

`connect skills` is the one target with no button, because it is a Cairn
feature rather than an agent: it installs the `cairn-save` skill for Claude Code
and Codex. Ask either agent to "save this to Cairn", or run `/cairn-save`, and
it publishes a deliberate conclusion note that trails back to where it was
saved from — distinct from the automatic capture when a turn ends.

The per-agent installers (`install_*.py`) still exist and still work;
`cairn_connect.py` is what drives them.

### Onboarding, design, and release

Onboarding happens once, which makes it the hardest part to test.
`python3 Scripts/cairn_reset.py` walks it back — disconnects every agent,
clears the queue, the preferences, and the privacy grants, and leaves the app
in place — so the next launch is a first launch again. It prints its plan and
changes nothing until `--yes`; `--keep-permissions` spares the grants.

The protocol tests and the Swift tests lock opposite ends of
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

## Contributing

Bug reports, producers for other runtimes, and trail-back fixes are all
welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and run the doctor
before filing anything.

## License

Apache-2.0 — see [LICENSE](LICENSE).

The code is open. The **name "Cairn", the wordmark 跡, and the stone mark** are
not licensed with it — see [NOTICE](NOTICE).
