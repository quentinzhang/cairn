# Releasing Cairn

Cairn has two independent publishing paths:

- `main` is the source of the website. A change under `site/` is deployed to
  GitHub Pages automatically.
- A `vX.Y.Z` GitHub Release is the source of App downloads and of Cairn's
  once-a-day update check.

Apple signing and notarization happen on the release Mac, not in GitHub Actions.
This keeps the Developer ID certificate and App Store Connect credentials out
of repository secrets. GitHub receives only the finished, notarized files.

## One-time setup

Install and authenticate the GitHub CLI:

```bash
brew install gh
gh auth login
```

Store App Store Connect credentials in the macOS keychain:

```bash
xcrun notarytool store-credentials cairn-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

Use the app-specific password requested by `notarytool`. Never store the
password, certificate, or key in this repository.

Set the profile name once in the shell that performs releases:

```bash
export CAIRN_NOTARY_PROFILE=cairn-notary
```

As an alternative, use an existing App Store Connect Team API key without
creating another keychain item:

```bash
export ASC_KEY_PATH=/absolute/path/to/AuthKey_KEYID.p8
export ASC_KEY_ID=KEYID
export ASC_ISSUER_ID=ISSUER_UUID
```

The release scripts accept either authentication method and never copy or
print the API key. Do not configure `CAIRN_NOTARY_PROFILE` and `ASC_KEY_*` at
the same time; the scripts reject ambiguous authentication instead of silently
using a different credential than the one being tested.

App Store Connect Individual API keys cannot use `notarytool`; Cairn requires
a Team API key with its Issuer UUID when API-key authentication is selected.
The release scripts run zsh with startup files disabled so stale `ASC_*` values
in `~/.zshenv` cannot silently replace the explicitly selected method.

The default signing identity is:

```text
Developer ID Application: Yue Zhang (JFF5GV3L69)
```

Override it with `CAIRN_SIGN_IDENTITY` only if the official signing identity
changes.

## Publish a new App version

AI agents must use the repository release skill instead of reconstructing the
workflow from memory:

```text
.agents/skills/cairn-release/SKILL.md
```

Run its read-only gates before mutating the release:

```bash
.agents/skills/cairn-release/scripts/preflight.sh source
.agents/skills/cairn-release/scripts/preflight.sh credentials
.agents/skills/cairn-release/scripts/preflight.sh release --version 0.7.0
```

Start from a clean `main` branch:

```bash
git pull --ff-only
./Scripts/release.sh --version 0.7.0
```

That single command:

1. confirms the local commit matches `origin/main` and its GitHub CI passed;
2. chooses the next bundle build number;
3. updates `Resources/Info.plist`;
4. runs the Swift, protocol, and OpenClaw checks;
5. builds, signs, notarizes, staples, and Gatekeeper-validates the ZIP and DMG;
6. commits the version, creates `v0.7.0`, and pushes both atomically;
7. creates the GitHub Release with generated notes;
8. uploads the ZIP, DMG, and SHA-256 checksum file;
9. reads the public release back and verifies all three assets exist.

Use curated release notes when needed:

```bash
./Scripts/release.sh \
  --version 0.7.0 \
  --notes-file /absolute/path/to/release-notes.md
```

The build number normally increments automatically. To choose it explicitly:

```bash
./Scripts/release.sh --version 0.7.0 --build 13
```

Do not create tags or upload files by hand before running the script. The App
uses the latest GitHub Release tag as its update source, and expects tags in
`vX.Y.Z` form.

After publication, verify fresh public downloads rather than reusing local
artifacts:

```bash
.agents/skills/cairn-release/scripts/verify_release.sh 0.7.0 <build>
```

## Update the website

Preview the static site:

```bash
python3 -m http.server 8080 --directory site
open http://localhost:8080
```

Edit files under `site/`, then commit and push:

```bash
git add site
git commit -m "Update website"
git push origin main
```

The `Pages` workflow deploys it to:

```text
https://quentinzhang.github.io/cairn/
```

The Download button always points to `/releases/latest`, so publishing a new
App version does not require a website edit.

## Recovery

Before the release commit is created, a failed run restores
`Resources/Info.plist`. After a commit or tag has been created, stop and inspect
the exact state:

```bash
git status
git log -1 --decorate
gh release view v0.7.0
```

Do not delete a published release or reuse a version number after users may have
downloaded it. Fix the cause and publish the next patch version.
