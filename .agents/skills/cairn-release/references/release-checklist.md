# Cairn release checklist

## Before mutation

- Confirm repository root, `main`, `origin`, upstream, and public repository.
- Read modified and untracked files; preserve unrelated user work.
- Reject merge conflicts, credentials, `.p8`, certificates, archives, DMGs,
  `.env` files, and local build output from Git history.
- Read current version/build from `Resources/Info.plist`.
- Read the latest public GitHub Release and choose a strictly newer semantic
  version.
- Confirm whether release notes are generated or curated.
- Choose exactly one notarization method.

## Source and credential gates

- `preflight.sh source` passes.
- `git diff --check` and `git diff --cached --check` pass.
- Swift tests pass.
- 171 protocol checks pass.
- OpenClaw contract and Node tests pass.
- Developer ID identity is installed.
- `preflight.sh credentials` proves `notarytool history` authentication.
- API Key values are never printed, copied into the repo, or added to notes.

## Git and CI gate

- Intended feature changes are committed.
- `main` and `origin/main` match.
- Working tree is clean.
- Exact feature commit has completed successful GitHub CI.
- Target tag and GitHub Release do not already exist.

## Local release gates

- `Scripts/release.sh` is the entry point.
- App signature is valid and includes the Apple Events entitlement.
- App notarization returns `Accepted`.
- App ticket staples and validates.
- App Gatekeeper result is `accepted` with `source=Notarized Developer ID`.
- ZIP is created after App stapling with `ditto`.
- DMG is signed, notarized, stapled, and validated.
- DMG Gatekeeper uses `--type open --context context:primary-signature`.
- SHA-256 file includes the final ZIP and DMG.
- Release commit and annotated `vX.Y.Z` tag point to the intended code.

## Public verification

- `.agents/skills/cairn-release/scripts/verify_release.sh X.Y.Z [build]` passes
  against fresh public downloads and the exact release commit's CI.
- GitHub Release is latest, non-draft, and non-prerelease.
- Latest API returns `vX.Y.Z`.
- Assets are exactly:
  - `Cairn-X.Y.Z-mac.zip`
  - `Cairn-X.Y.Z.dmg`
  - `Cairn-X.Y.Z-SHA256SUMS.txt`
- Latest-download routes redirect to the selected tag.
- Fresh downloads pass the published SHA-256 file.
- Extracted App and downloaded DMG pass signature, stapler, and Gatekeeper.
- GitHub Pages website returns HTTP 200.
- Final release commit CI succeeds.
- Local `main`, `origin/main`, and tag resolve to the expected release commit.
- Working tree is clean.

## Final report

- Version and build.
- Feature commit and release commit.
- Tag and Release URL.
- CI run URL/result.
- Asset names, sizes, and SHA-256 values.
- Apple submission acceptance and Gatekeeper results.
- Website URL and latest API result.
- Any unproven or intentionally skipped check.
