#!/bin/zsh
set -euo pipefail

# Package a distributable Cairn: Developer ID signing, notarization, stapling,
# and a Gatekeeper assessment of every artifact before any of it is reported as
# ready. Nothing here is publishable until spctl accepts it.
#
# Credentials live in a notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
# The profile belongs to the Apple Developer *account*, not to this app, so a
# profile created for another app on the same team works unchanged.
#
# Two artifacts, on purpose:
#   .zip  stapled, signature-preserving (ditto), what an updater downloads
#   .dmg  stapled, what a human downloads
# Both are built from the app *after* stapling, so a download works offline.

root="${0:A:h:h}"
plist="$root/Resources/Info.plist"
sign_identity="${CAIRN_SIGN_IDENTITY:-Developer ID Application: Yue Zhang (JFF5GV3L69)}"
notary_profile="${CAIRN_NOTARY_PROFILE:-}"
new_version=""
new_build=""
skip_notarization=0

usage() {
  cat <<'EOF'
Usage: ./Scripts/package_release.sh [options]

  --version <semver>       Set CFBundleShortVersionString before building.
  --build <number>         Set CFBundleVersion before building.
  --notary-profile <name>  notarytool keychain profile. Or set CAIRN_NOTARY_PROFILE.
  --sign-identity <name>   Developer ID identity. Or set CAIRN_SIGN_IDENTITY.
  --skip-notarization      Build and sign only. Produces artifacts Gatekeeper
                           will reject — for verifying the pipeline, never for
                           distribution.
  --help

Examples:
  ./Scripts/package_release.sh --notary-profile my-notary
  ./Scripts/package_release.sh --version 1.0.0 --build 11 --notary-profile my-notary
  ./Scripts/package_release.sh --skip-notarization
EOF
}

log() { print -r -- "" && print -r -- "[$(date '+%H:%M:%S')] $*" }
die() { print -r -- "Error: $*" >&2; exit 2 }

while (( $# )); do
  case "$1" in
    --version)         new_version="${2:-}"; shift 2 ;;
    --build)           new_build="${2:-}"; shift 2 ;;
    --notary-profile)  notary_profile="${2:-}"; shift 2 ;;
    --sign-identity)   sign_identity="${2:-}"; shift 2 ;;
    --skip-notarization) skip_notarization=1; shift ;;
    --help)            usage; exit 0 ;;
    *)                 die "Unknown argument: $1" ;;
  esac
done

for tool in codesign ditto hdiutil shasum spctl xcrun /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing required command: $tool"
done

(( skip_notarization )) || [[ -n "$notary_profile" ]] || \
  die "Set --notary-profile (or CAIRN_NOTARY_PROFILE) to a notarytool keychain profile."

security find-identity -v -p codesigning | grep -qF "$sign_identity" || \
  die "Developer ID identity not found: $sign_identity"

# Fail before a five-minute build rather than at the upload.
if (( ! skip_notarization )); then
  xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 || \
    die "notarytool profile '$notary_profile' is missing or its credentials are invalid."
fi

[[ -n "$new_version" ]] && \
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_version" "$plist"
[[ -n "$new_build" ]] && \
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new_build" "$plist"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")

app="$root/dist/Cairn.app"
submission="$root/dist/Cairn-$version-notarization.zip"
archive="$root/dist/Cairn-$version-mac.zip"
dmg="$root/dist/Cairn-$version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/cairn-release.XXXXXX")
trap '/bin/rm -rf "$staging" "$submission"' EXIT

log "Building Cairn $version ($build), bundle id $bundle_id"
CAIRN_SIGN_IDENTITY="$sign_identity" "$root/Scripts/build_app.sh"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements :- "$app" 2>/dev/null |
  grep -q '<key>com.apple.security.automation.apple-events</key>' || \
  die "Signed app is missing the Apple Events entitlement."
codesign -dv --verbose=4 "$app" 2>&1 | \
  sed -n '/^Identifier=/p;/^CodeDirectory/p;/^Authority=/p;/^TeamIdentifier=/p;/^Timestamp=/p'

/bin/rm -f "$submission" "$archive" "$dmg"

if (( skip_notarization )); then
  log "Skipping notarization — these artifacts are NOT distributable"
else
  log "Submitting the app for notarization"
  # ditto -c -k --keepParent is the only archiver that preserves a bundle's
  # signature and extended attributes intact.
  ditto -c -k --keepParent "$app" "$submission"
  xcrun notarytool submit "$submission" --keychain-profile "$notary_profile" --wait

  log "Stapling the ticket to the app"
  # Staple before packaging, so both artifacts carry the ticket and validate
  # without a network round trip on the user's machine.
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
fi

log "Creating the distributable zip"
ditto -c -k --keepParent "$app" "$archive"

log "Creating the DMG"
cp -R "$app" "$staging/Cairn.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Cairn" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp --sign "$sign_identity" "$dmg"

if (( ! skip_notarization )); then
  log "Notarizing the DMG"
  xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
fi

log "Release ready"
print -r -- "Version:    $version ($build)"
print -r -- "Bundle id:  $bundle_id"
print -r -- "Identity:   $sign_identity"
for artifact in "$archive" "$dmg"; do
  print -r -- ""
  print -r -- "$artifact"
  print -r -- "  size    $(du -h "$artifact" | awk '{print $1}')"
  print -r -- "  sha256  $(shasum -a 256 "$artifact" | awk '{print $1}')"
done
print -r -- ""
(( skip_notarization )) && print -r -- "NOT NOTARIZED — do not distribute these."
print -r -- "Tag the GitHub release v$version — UpdateChecker strips the leading v."
