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

The default signing identity is:

```text
Developer ID Application: Yue Zhang (JFF5GV3L69)
```

Override it with `CAIRN_SIGN_IDENTITY` only if the official signing identity
changes.

## Publish a new App version

Start from a clean `main` branch:

```bash
git pull --ff-only
./Scripts/release.sh --version 0.7.0
```

That single command:

1. chooses the next bundle build number;
2. updates `Resources/Info.plist`;
3. runs the Swift, protocol, and OpenClaw checks;
4. builds, signs, notarizes, staples, and Gatekeeper-validates the ZIP and DMG;
5. commits the version, creates `v0.7.0`, and pushes both atomically;
6. creates the GitHub Release with generated notes;
7. uploads the ZIP, DMG, and SHA-256 checksum file;
8. reads the public release back and verifies all three assets exist.

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
