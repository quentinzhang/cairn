# Contributing to Cairn

Thanks for looking. Cairn is small on purpose, and the fastest way to get a
change merged is to understand what it is trying to be.

## Before anything else: run the doctor

Almost every "notes stopped arriving" report has a cause the doctor already
knows about — a hook pointing at a moved checkout, a plugin linked but not
enabled, a malformed payload wedged in the inbox, an untrusted Codex hook.

```bash
python3 Scripts/cairn_doctor.py
```

If you are filing a bug, paste that output. It is designed to be safe to share:
no note bodies, no prompts, no absolute paths outside the checkout. To also
verify the whole publish path end to end:

```bash
python3 Scripts/cairn_doctor.py --probe
```

## Building

```bash
./Scripts/build_app.sh
open dist/Cairn.app
swift test
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16 or newer). There are no
package dependencies to fetch — Cairn uses only system frameworks, the Python 3
standard library, and the Node.js standard library, and it intends to stay that
way. A PR that adds a third-party dependency needs to argue for it.

`build_app.sh` signs with a Developer ID by default and silently falls back to
ad-hoc signing when the certificate is absent, so it works on any machine.
Ad-hoc signatures change every build, which makes macOS treat each build as a
new app and drop your Accessibility and Automation grants. Set
`CAIRN_SIGN_IDENTITY` to a stable identity if you are working on the
trail-back features. The script must also sign with
`Resources/Cairn.entitlements`: Developer ID builds use Hardened Runtime, and
without `com.apple.security.automation.apple-events` macOS denies Automation
requests before showing a prompt or registering Cairn in System Settings.

**Do not change `CFBundleIdentifier`** (`app.cairn.Cairn` in
[`Resources/Info.plist`](Resources/Info.plist)). macOS keys Accessibility and
per-application Automation grants to that string and offers no migration path,
so changing it silently revokes precise trail-back for every existing user and
resets their preferences — with no prompt explaining why. This note lives here
rather than in the plist because `PlistBuddy`, which `package_release.sh` uses
for `--version` and `--build`, rewrites the file and discards comments.

## What Cairn is

- **A queue of conclusions.** The final answer, not progress, not tool logs, not
  reasoning. If a change makes Cairn show more of what an agent did rather than
  what it concluded, it is going the wrong way.
- **Quiet.** No Dock icon, no system notifications, no focus stealing, no badge
  that demands attention. The floating control is non-activating by design.
  "Add a notification for X" is almost always a no.
- **Local.** No network service, no account, no telemetry, no analytics. The
  only outbound request in the entire app is a GitHub Releases check, run once
  a day or when the user explicitly asks. Automatic failures stay silent. A PR
  that adds a second destination needs a very good reason.
- **Deferential to the agent it hooks.** A bridge must never break, block, or
  slow the runtime it runs inside. Swallow every error, exit 0, finish fast. See
  [`docs/inbox-protocol.md`](docs/inbox-protocol.md) §8.

## Where changes go

| You want to… | Start here |
| --- | --- |
| Support another agent runtime | Write a producer against [`docs/inbox-protocol.md`](docs/inbox-protocol.md). You do **not** need to change the app. |
| Add a colour/name for your source | `Cairn.Agent.identity(for:)` in [`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift) |
| Change a colour, radius, or duration | [`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift) and [`docs/design-system.md`](docs/design-system.md) — never inline in a view |
| Improve trail-back / 寻迹 | [`Sources/Cairn/TrailFinder.swift`](Sources/Cairn/TrailFinder.swift) |
| Change the panel, queue, or menu bar | [`Sources/Cairn/CairnApp.swift`](Sources/Cairn/CairnApp.swift) |
| Change permission onboarding | [`Sources/Cairn/PermissionOnboarding.swift`](Sources/Cairn/PermissionOnboarding.swift) |
| Change interface copy or add a language | [`Sources/Cairn/Resources/`](Sources/Cairn/Resources/) — keep every locale's key set identical |
| Change update checks | [`Sources/Cairn/UpdateChecker.swift`](Sources/Cairn/UpdateChecker.swift) and its menu presentation in [`Sources/Cairn/CairnApp.swift`](Sources/Cairn/CairnApp.swift) |
| Change the inbox contract itself | [`docs/inbox-protocol.md`](docs/inbox-protocol.md), as its own PR, discussed before code |

### Adding support for a new agent

This is the contribution most likely to be accepted, and it usually needs no
change to the Swift app at all. Write something that publishes a JSON file per
completed turn, following the protocol. Then:

1. Add an installer under `Scripts/` that **preserves every existing setting**
   in the runtime's config. Cairn's installers merge one handler and can remove
   exactly that handler again; they never rewrite a user's file. Support
   `install` and `uninstall`.
2. Add a section to `cairn_doctor.py` — skipped entirely when that runtime is
   not installed, and specific about what is wrong when it is.
3. Add the source to `identity(for:)` if you want a dedicated colour.
4. Document it in the README next to the other runtimes.

## House style

The existing code is the specification. Match it rather than your own habits.

- **Comments explain why, never what.** Look at the comment above `host_apps` in
  [`Scripts/cairn_locator.py`](Scripts/cairn_locator.py) or the signing note in
  `build_app.sh` — each one records a non-obvious constraint that a reader would
  otherwise remove. If a comment restates the code, delete it.
- Swift: no magic numbers in views. Every colour, radius, duration, and
  dimension resolves through the `Cairn` namespace. Add the token first.
- Python: standard library only, `from __future__ import annotations`, and it
  must run under `/usr/bin/python3` (3.9 on current macOS) because that is the
  interpreter the installed hooks invoke.
- Prose in the UI and docs is plain, quiet, and unexcited. No exclamation marks,
  no "just", no marketing.

## Pull requests

- One concern per PR. A design change and a protocol change are two PRs.
- Say what you observed, not only what you changed — especially for trail-back
  fixes, which depend on terminal and app specifics that reviewers may not have.
- Include the doctor's output when the change touches a bridge or installer.
- `swift test` must pass. UI behaviour usually cannot be tested here; describe
  what you exercised by hand instead.
- By opening a PR you agree to license your contribution under Apache-2.0 (see
  [LICENSE](LICENSE)). There is no CLA.

## Naming and branding

The code is Apache-2.0. The name "Cairn", the wordmark 跡, and the stone mark
are not — see [NOTICE](NOTICE). Fork freely; if you ship a modified build, give
it your own name and icon so users can tell it apart from an official release.
Saying your tool "publishes to Cairn" or "implements the Cairn inbox protocol"
is always fine.

## Security and privacy

Cairn handles the contents of your agent conversations. Do not report a
vulnerability in a public issue — see [SECURITY.md](SECURITY.md).
