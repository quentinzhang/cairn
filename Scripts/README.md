# Scripts reference

This directory contains both developer-facing commands and implementation
details copied into `Cairn.app`. They are not all equivalent entry points.
Prefer the high-level commands below; call an installer or hook directly only
when working on that integration.

All examples assume the repository root as the current directory.

## Everyday development entry points

| Script | Purpose | Direct use and side effects |
| --- | --- | --- |
| [`build_app.sh`](build_app.sh) | Builds the Swift target in release mode, assembles the complete `dist/Cairn.app`, copies every bridge and plugin, adds resources and entitlements, and signs the bundle. | **Run directly.** Writes `.build/` and `dist/`; it does not install the App or publish a release. |
| [`cairn_connect.py`](cairn_connect.py) | Reports every supported runtime and connects or disconnects Codex, Claude Code, OpenClaw, OpenCode, Hermes, and the optional `cairn-save` skills. This is the backend used by the App's **Apps** window. | **Run directly.** `status` is read-only. `connect` and `disconnect` modify agent configuration; OpenClaw operations can restart its Gateway. |
| [`cairn_doctor.py`](cairn_doctor.py) | Diagnoses missing notes, stale hooks, plugin state, malformed inbox payloads, and duplicate App copies. | **Run directly.** The default check is read-only; `--probe` publishes and consumes a real test note. |
| [`cairn_reset.py`](cairn_reset.py) | Returns this Mac to Cairn's first-run state so onboarding can be exercised again. | **Run directly with care.** The default is a dry run. `--yes` quits Cairn, disconnects agents, deletes Cairn notes and preferences, and resets Accessibility and Automation grants unless the matching `--keep-*` flags are supplied. |
| [`cairn_save.py`](cairn_save.py) | Publishes a deliberate note to Cairn from a human, an agent skill, CI, or another local process. | **Run directly.** Writes one atomic payload into Cairn's inbox; it does not change agent configuration. |

Common commands:

```bash
./Scripts/build_app.sh
python3 Scripts/cairn_connect.py status
python3 Scripts/cairn_doctor.py
echo "Build completed successfully." | python3 Scripts/cairn_save.py --source ci
python3 Scripts/cairn_reset.py                    # dry run
```

## Runtime hooks

These scripts are registered in an agent's lifecycle configuration and receive
event data from that runtime. They isolate every failure so a Cairn problem
cannot break the agent.

| Script | Purpose | Direct use and side effects |
| --- | --- | --- |
| [`cairn_codex_hook.py`](cairn_codex_hook.py) | Handles Codex `Stop` events, extracts the final assistant result and latest user prompt from the transcript, ignores internal memory work, captures trail metadata, and publishes a Cairn payload. | **Runtime-invoked.** Reads JSON from stdin and may write an inbox payload. It is not a diagnostic command. |
| [`cairn_claude_hook.py`](cairn_claude_hook.py) | Handles Claude Code `Stop` events, prefers `last_assistant_message`, uses the transcript for compatible fallback and prompt recovery, captures trail metadata, and publishes a Cairn payload. | **Runtime-invoked.** Reads JSON from stdin and may write an inbox payload. It is not a diagnostic command. |

Hermes, OpenClaw, and OpenCode use the source-backed plugin directories at the
repository root rather than Python hook scripts:
[`HermesPlugin/`](../HermesPlugin/),
[`OpenClawPlugin/`](../OpenClawPlugin/), and
[`OpenCodePlugin/`](../OpenCodePlugin/).

## Shared implementation modules

| Script | Purpose | Direct use and side effects |
| --- | --- | --- |
| [`cairn_locator.py`](cairn_locator.py) | Captures the environment and process ancestry needed to return to the terminal tab, host App, browser session, or conversation where a turn ran. | **Import only.** Used by producers such as the hooks and `cairn_save.py`; failures intentionally degrade to partial or empty locator data. |
| [`cairn_payload.py`](cairn_payload.py) | Resolves plugin and skill payload directories in both repository and installed-App layouts, and provides the shared private inbox writer used by Python producers. | **Import only.** Its path resolver is read-only; its inbox helpers create or repair Cairn's local storage when a producer publishes. |

## Low-level installers

Prefer `cairn_connect.py connect <runtime>` and
`cairn_connect.py disconnect <runtime>`. These lower-level commands are kept
for integration development and recovery.

| Script | Purpose | Direct use and side effects |
| --- | --- | --- |
| [`install_codex_hook.py`](install_codex_hook.py) | Adds or removes Cairn's Codex `Stop` handler while preserving every unrelated hook. | **Low-level, mutating.** Updates `~/.codex/hooks.json`. |
| [`install_claude_hook.py`](install_claude_hook.py) | Adds or removes Cairn's Claude Code `Stop` handler while preserving unrelated settings and hooks. | **Low-level, mutating.** Updates `~/.claude/settings.json`. |
| [`install_hermes_plugin.py`](install_hermes_plugin.py) | Links the source-backed Cairn plugin into Hermes and enables or disables it through the Hermes CLI. | **Low-level, mutating.** Manages `~/.hermes/plugins/cairn` and Hermes plugin state; refuses to replace a real directory. |
| [`install_openclaw_plugin.py`](install_openclaw_plugin.py) | Installs or removes the Cairn OpenClaw plugin, manages conversation-access compatibility, and can restart the managed Gateway. | **Low-level, mutating.** Changes OpenClaw plugin configuration and may restart its Gateway. |
| [`install_opencode_plugin.py`](install_opencode_plugin.py) | Links Cairn's OpenCode plugin into OpenCode without editing its config file. | **Low-level, mutating.** Manages `~/.config/opencode/plugins/cairn.js`; refuses to replace a real file or directory. |
| [`install_agent_skills.py`](install_agent_skills.py) | Installs or removes the `cairn-save` wrapper for Claude Code and Codex. | **Low-level, mutating.** Writes `~/.claude/skills/cairn-save/SKILL.md` and `~/.codex/prompts/cairn-save.md`. |

Each installer accepts `install` or `uninstall`; omitting the action defaults
to `install`. OpenClaw additionally exposes consent and Gateway restart flags.

## Build, artwork, and release operations

| Script | Purpose | Direct use and side effects |
| --- | --- | --- |
| [`generate_app_icon.sh`](generate_app_icon.sh) | Runs the Swift icon renderer, generates every macOS icon size, and assembles the final `.icns`. | **Run directly after an intentional brand change.** Rewrites `Resources/AppIcon-1024.png` and `Resources/AppIcon.icns`. |
| [`generate_app_icon.swift`](generate_app_icon.swift) | Draws the 1024×1024 source icon used by `generate_app_icon.sh`. | **Implementation helper.** Normally invoked by the shell wrapper; writes the output path passed on the command line. |
| [`package_release.sh`](package_release.sh) | Builds, Developer-ID-signs, notarizes, staples, Gatekeeper-checks, and packages local ZIP and DMG artifacts. | **Maintainer command.** Writes `dist/` and can update `Resources/Info.plist` when version/build options are supplied. It submits to Apple notarization but does not commit, tag, push, or publish to GitHub. |
| [`release.sh`](release.sh) | Performs the complete public release workflow: source and CI gates, tests, versioning, packaging, checksums, release commit, tag, atomic push, GitHub Release upload, and public verification. | **Official maintainer command only.** Mutates Git history and publishes externally. It must start from a clean, synchronized `main`; AI agents on the maintainer's machine should use the maintainer-local `cairn-release` skill (under `.agents/`, not distributed with this repository) rather than reconstructing the flow manually. |

See [`docs/releasing.md`](../docs/releasing.md) for release credentials,
preflight checks, recovery, and the difference between local packaging and a
public release.
