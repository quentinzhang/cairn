---
name: cairn-release
description: Preflight, sign, notarize, tag, publish, and verify a production release of the Cairn macOS app from this repository. Use when the user asks an AI agent to release, publish, package, notarize, upload, tag, or verify a Cairn version, update the official download, diagnose App Store Connect API Key or notarytool failures, or check release readiness. This skill is repository-specific and must use Scripts/release.sh and Scripts/package_release.sh as the execution sources of truth.
---

# Cairn Release

Use this skill only in the Cairn repository containing `Package.swift`,
`Resources/Info.plist`, `Scripts/release.sh`, and `site/`.

## Sources of truth

- Version and build: `Resources/Info.plist`.
- Tests and bundle assembly: `Package.swift`, `.github/workflows/ci.yml`,
  and `Scripts/build_app.sh`.
- Production orchestration: `Scripts/release.sh`.
- Signing, notarization, stapling, ZIP, and DMG creation:
  `Scripts/package_release.sh`.
- Operator guide and recovery: `docs/releasing.md`.
- Public update source:
  `https://api.github.com/repos/quentinzhang/cairn/releases/latest`.

Do not recreate the release with ad-hoc signing, `zip`, `hdiutil`, tag, or
upload commands while the repository scripts support the operation.

## Resolve the release scope

Before changing files, resolve:

- The target semantic version and optional explicit build number.
- Whether existing uncommitted changes belong in the release.
- Whether release notes should be generated or supplied with `--notes-file`.
- Which single notarization method will be used.

When the user asks for a new version without a number, choose the next patch
version above the latest public GitHub Release and increment the current bundle
build by one. State the selected version and build before publication.

## Notarization authentication

Choose exactly one method:

1. Keychain profile: set `CAIRN_NOTARY_PROFILE`.
2. Team App Store Connect API Key: set `ASC_KEY_PATH`, `ASC_KEY_ID`, and
   `ASC_ISSUER_ID`.

Never set a keychain profile and any `ASC_KEY_*` value together. Never print,
copy, stage, or commit `.p8` content. `ASC_ISSUER_ID` is an App Store Connect
Issuer UUID, not the 10-character Apple Developer Team ID.
Reject Individual API keys before building; Apple documents that they cannot
use `notarytool`.

The release scripts run zsh with `-f` so `~/.zshenv` cannot silently re-add a
stale `ASC_*` tuple after the agent selected or cleared credentials.

Run the credential gate before a release build:

```bash
.agents/skills/cairn-release/scripts/preflight.sh credentials
```

If it fails, stop and read
`references/notarization-api-key.md`. Do not debug authentication by repeatedly
submitting release archives.

## Workflow

1. Read `references/release-checklist.md` and, for API Key authentication,
   `references/notarization-api-key.md`.
2. Inspect `git status`, the full relevant diff, current version/build, tags,
   latest public Release, and recent CI. Preserve unrelated user changes.
3. Run the read-only source gate:

   ```bash
   .agents/skills/cairn-release/scripts/preflight.sh source
   ```

4. Finish and test intended release changes. Review all modified and untracked
   files for secrets, credentials, build output, and accidental files.
5. Commit and push the intended feature changes to `main`. Wait for the exact
   commit's GitHub CI to complete successfully.
6. Require a clean, synchronized `main`, then run:

   ```bash
   .agents/skills/cairn-release/scripts/preflight.sh release --version <version>
   ```

7. Publish through the repository entry point:

   ```bash
   ./Scripts/release.sh --version <version>
   ```

   Add `--build <number>` only when intentionally overriding the automatic
   build. Add `--notes-file /absolute/path/to/notes.md` for curated notes.

8. Require every local gate to pass: Swift tests, protocol checks, OpenClaw
   tests, Developer ID signature, Apple notarization acceptance for the App and
   DMG, stapler validation, Gatekeeper assessment, and checksum creation.
9. Verify production from public surfaces:

   ```bash
   .agents/skills/cairn-release/scripts/verify_release.sh <version> <build>
   ```

   The verifier must prove:

   - CI succeeds for the exact commit referenced by `v<version>`.
   - GitHub latest API returns `v<version>`.
   - Release is neither draft nor prerelease.
   - ZIP, DMG, and checksum assets exist.
   - `/releases/latest/download/...` redirects to `v<version>`.
   - Freshly downloaded ZIP and DMG match the published checksums.
   - ZIP-contained App and DMG pass signature, stapler, and Gatekeeper checks.
   - `https://quentinzhang.github.io/cairn/` remains reachable.

10. Report feature commit, release commit, tag, CI run, version/build, Release
    URL, asset names, SHA-256 values, notarization result, and clean Git state.

## Safety boundaries

- A local `dist/` artifact is not a production release.
- A pushed tag without a non-draft GitHub Release is not discoverable through
  Cairn's update checker.
- Never use `--skip-notarization` for distributed artifacts.
- Never publish after a failed test, signature, notarization, staple,
  Gatekeeper, checksum, CI, or public read-back gate.
- Never delete or replace a published Release or reuse its version. Fix the
  cause and publish the next patch.
- Do not force-push, rewrite history, reset user work, or commit credentials.
- Do not launch a second Cairn instance for visual QA without isolating its
  inbox; duplicate instances can consume the same completion files.

## Recovery

Before a release commit exists, `Scripts/release.sh` restores
`Resources/Info.plist` after failure. After a commit, tag, push, or Release
creation, stop automation and inspect:

```bash
git status
git log -2 --decorate
git ls-remote origin refs/heads/main refs/tags/v<version>
gh release view v<version> --repo quentinzhang/cairn
```

Resume only the missing publication step when its inputs are already verified;
do not rerun the whole release script against an existing tag.

## Completion criteria

A Cairn production release is complete only when the public latest API, all
three assets, downloaded checksums, notarization tickets, Gatekeeper, website,
exact release CI, tag, remote `main`, and local clean state are verified.
