#!/bin/zsh
set -euo pipefail

# The public release entry point. Apple credentials stay in the local keychain:
# this script validates, signs, notarizes and staples locally, then publishes
# only the finished artifacts through GitHub.

root="${0:A:h:h}"
plist="$root/Resources/Info.plist"
github_repository="${CAIRN_GITHUB_REPOSITORY:-quentinzhang/cairn}"
notary_profile="${CAIRN_NOTARY_PROFILE:-}"
sign_identity="${CAIRN_SIGN_IDENTITY:-Developer ID Application: Yue Zhang (JFF5GV3L69)}"
version=""
build=""
notes_file=""

usage() {
  cat <<'EOF'
Usage: ./Scripts/release.sh --version <semver> [options]

  --version <semver>       Public version, for example 0.7.0.
  --build <number>         Bundle build number. Defaults to the next build.
  --notes-file <path>      Markdown release notes. GitHub generates notes when omitted.
  --notary-profile <name>  notarytool keychain profile. Or set CAIRN_NOTARY_PROFILE.
  --sign-identity <name>   Developer ID identity. Or set CAIRN_SIGN_IDENTITY.
  --repo <owner/name>      GitHub repository. Defaults to quentinzhang/cairn.
  --help

Example:
  CAIRN_NOTARY_PROFILE=cairn-notary \
    ./Scripts/release.sh --version 0.7.0
EOF
}

log() { print -r -- "" && print -r -- "[$(date '+%H:%M:%S')] $*" }
die() { print -r -- "Error: $*" >&2; exit 2 }

while (( $# )); do
  case "$1" in
    --version)         version="${2:-}"; shift 2 ;;
    --build)           build="${2:-}"; shift 2 ;;
    --notes-file)      notes_file="${2:-}"; shift 2 ;;
    --notary-profile)  notary_profile="${2:-}"; shift 2 ;;
    --sign-identity)   sign_identity="${2:-}"; shift 2 ;;
    --repo)            github_repository="${2:-}"; shift 2 ;;
    --help)            usage; exit 0 ;;
    *)                 die "Unknown argument: $1" ;;
  esac
done

[[ -n "$version" ]] || die "--version is required."
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || \
  die "--version must contain exactly three numeric components, such as 0.7.0."
[[ -n "$notary_profile" ]] || \
  die "Set --notary-profile (or CAIRN_NOTARY_PROFILE) to a notarytool keychain profile."
[[ -z "$notes_file" || -f "$notes_file" ]] || die "Release notes file not found: $notes_file"

for tool in git gh swift node /usr/bin/python3 /usr/libexec/PlistBuddy shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing required command: $tool"
done

cd "$root"
[[ "$(git branch --show-current)" == "main" ]] || die "Releases must start on the main branch."
[[ -z "$(git status --porcelain)" ]] || die "Commit or stash every change before releasing."
[[ -n "$(git remote get-url origin 2>/dev/null || true)" ]] || die "The origin remote is not configured."
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"

visibility=$(gh repo view "$github_repository" --json visibility --jq .visibility 2>/dev/null || true)
[[ "$visibility" == "PUBLIC" ]] || \
  die "$github_repository must exist and be public before a release can be published."
origin_repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
[[ "${origin_repository:l}" == "${github_repository:l}" ]] || \
  die "origin resolves to $origin_repository, not $github_repository."

git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
  die "Local main is not synchronized with origin/main. Pull or push before releasing."

tag="v$version"
git rev-parse "$tag" >/dev/null 2>&1 && die "Tag $tag already exists locally."
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && \
  die "Tag $tag already exists on origin."
gh release view "$tag" --repo "$github_repository" >/dev/null 2>&1 && \
  die "GitHub Release $tag already exists."

current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
current_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
[[ "$current_build" =~ '^[0-9]+$' ]] || die "Current CFBundleVersion is not numeric: $current_build"

if [[ -z "$build" ]]; then
  if [[ "$version" == "$current_version" ]]; then
    build="$current_build"
  else
    build=$(( current_build + 1 ))
  fi
fi
[[ "$build" =~ '^[0-9]+$' ]] || die "--build must be a positive integer."
(( build > 0 )) || die "--build must be a positive integer."
if [[ "$version" != "$current_version" ]] && (( build <= current_build )); then
  die "A new version needs a build number greater than $current_build."
fi

version_is_older=$(/usr/bin/python3 - "$version" "$current_version" <<'PY'
import sys
candidate = tuple(map(int, sys.argv[1].split(".")))
current = tuple(map(int, sys.argv[2].split(".")))
print("yes" if candidate < current else "no")
PY
)
[[ "$version_is_older" == "no" ]] || die "$version is older than the current version $current_version."

rollback_dir=$(mktemp -d "${TMPDIR:-/tmp}/cairn-release-state.XXXXXX")
cp "$plist" "$rollback_dir/Info.plist"
release_commit_created=0

cleanup() {
  exit_status=$?
  if (( exit_status != 0 && release_commit_created == 0 )); then
    cp "$rollback_dir/Info.plist" "$plist"
    print -r -- "Restored Resources/Info.plist after the failed release." >&2
  fi
  /bin/rm -rf "$rollback_dir"
}
trap cleanup EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"

log "Validating Cairn $version ($build)"
swift test
/usr/bin/python3 Tests/protocol_roundtrip.py
node --input-type=module -e '
  import plugin from "./OpenClawPlugin/index.js";
  if (plugin.id !== "cairn" || typeof plugin.register !== "function") {
    throw new Error("OpenClaw plugin contract is invalid");
  }
'

log "Signing, notarizing and stapling release artifacts"
"$root/Scripts/package_release.sh" \
  --version "$version" \
  --build "$build" \
  --notary-profile "$notary_profile" \
  --sign-identity "$sign_identity"

archive="$root/dist/Cairn-$version-mac.zip"
dmg="$root/dist/Cairn-$version.dmg"
checksums="$root/dist/Cairn-$version-SHA256SUMS.txt"
[[ -f "$archive" && -f "$dmg" ]] || die "The release artifacts were not created."
(
  cd "$root/dist"
  shasum -a 256 "${archive:t}" "${dmg:t}" > "${checksums:t}"
)

tracked_changes=$(git status --porcelain --untracked-files=no)
unexpected_changes=$(print -r -- "$tracked_changes" | awk '$2 != "Resources/Info.plist" { print }')
[[ -z "$unexpected_changes" ]] || die "Release changed unexpected tracked files:\n$unexpected_changes"

if ! git diff --quiet -- "$plist"; then
  log "Committing the version"
  git add "$plist"
  git commit -m "Release $tag"
  release_commit_created=1
fi

log "Tagging and pushing $tag"
git tag -a "$tag" -m "Cairn $version"
git push --atomic origin main "refs/tags/$tag"

log "Publishing the GitHub Release"
release_arguments=(
  "$tag"
  "$archive"
  "$dmg"
  "$checksums"
  --repo "$github_repository"
  --verify-tag
  --title "Cairn $version"
  --latest
)
if [[ -n "$notes_file" ]]; then
  release_arguments+=(--notes-file "$notes_file")
else
  release_arguments+=(--generate-notes)
fi
gh release create "${release_arguments[@]}"

log "Verifying the public release"
published_assets=$(gh release view "$tag" --repo "$github_repository" \
  --json assets --jq '.assets[].name')
for expected in "${archive:t}" "${dmg:t}" "${checksums:t}"; do
  print -r -- "$published_assets" | grep -qxF "$expected" || \
    die "Published release is missing $expected."
done

release_url=$(gh release view "$tag" --repo "$github_repository" --json url --jq .url)
print -r -- ""
print -r -- "Published Cairn $version ($build)"
print -r -- "Release: $release_url"
print -r -- "Website: https://${github_repository%%/*}.github.io/${github_repository##*/}/"
