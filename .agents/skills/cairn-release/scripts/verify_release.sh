#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
EXPECTED_BUILD="${2:-}"
GITHUB_REPOSITORY="${CAIRN_GITHUB_REPOSITORY:-quentinzhang/cairn}"
WEBSITE_URL="${CAIRN_WEBSITE_URL:-https://quentinzhang.github.io/cairn/}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

wait_for_release_ci() {
  local release_sha="$1"
  local timeout_seconds="${CAIRN_VERIFY_CI_TIMEOUT_SECONDS:-900}"
  local deadline
  local run_record=""
  local run_state=""
  local previous_state=""
  local run_status=""
  local run_conclusion=""
  local run_url=""

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || \
    fail "CAIRN_VERIFY_CI_TIMEOUT_SECONDS must be a non-negative integer."
  deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS <= deadline )); do
    run_record="$(gh run list \
      --repo "$GITHUB_REPOSITORY" \
      --workflow ci.yml \
      --commit "$release_sha" \
      --limit 1 \
      --json status,conclusion,url \
      --jq 'if length == 0 then "" else "\(.[0].status)\t\(.[0].conclusion // "")\t\(.[0].url)" end')"

    if [[ -z "$run_record" ]]; then
      run_state="missing"
    else
      IFS=$'\t' read -r run_status run_conclusion run_url <<<"$run_record"
      run_state="$run_status:${run_conclusion:-pending}"
      if [[ "$run_status" == "completed" ]]; then
        [[ "$run_conclusion" == "success" ]] || \
          fail "GitHub CI for $release_sha finished as $run_conclusion: $run_url"
        pass "GitHub CI succeeded for release commit $release_sha"
        return
      fi
    fi

    if [[ "$run_state" != "$previous_state" ]]; then
      printf 'INFO: Waiting for GitHub CI on %s (%s)\n' "$release_sha" "$run_state"
      previous_state="$run_state"
    fi
    sleep 5
  done

  fail "Timed out after ${timeout_seconds}s waiting for GitHub CI on $release_sha."
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "Usage: $0 <version> [build]"
[[ -z "$EXPECTED_BUILD" || "$EXPECTED_BUILD" =~ ^[0-9]+$ ]] || \
  fail "Build must be numeric."

for command_name in gh curl shasum ditto codesign spctl xcrun sleep /usr/libexec/PlistBuddy; do
  require_command "$command_name"
done

tag="v$VERSION"
archive="Cairn-$VERSION-mac.zip"
dmg="Cairn-$VERSION.dmg"
checksums="Cairn-$VERSION-SHA256SUMS.txt"
release_base="https://github.com/$GITHUB_REPOSITORY/releases/download/$tag"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/cairn-public-verify.XXXXXX")"

cleanup() {
  /bin/rm -rf "$verification_dir"
}
trap cleanup EXIT

is_draft="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
is_prerelease="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isPrerelease --jq .isPrerelease)"
[[ "$is_draft" == "false" ]] || fail "$tag is still a draft."
[[ "$is_prerelease" == "false" ]] || fail "$tag is a prerelease."

published_assets="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" \
  --json assets --jq '.assets[].name')"
for expected in "$archive" "$dmg" "$checksums"; do
  grep -qxF "$expected" <<<"$published_assets" || \
    fail "Published release is missing $expected."
done
pass "GitHub Release is public and contains all three assets"

latest_tag="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name)"
[[ "$latest_tag" == "$tag" ]] || fail "Latest API returns $latest_tag, expected $tag."
pass "GitHub latest API returns $tag"

release_sha="$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)"
[[ "$release_sha" =~ ^[[:xdigit:]]{40}$ ]] || \
  fail "Could not resolve $tag to a release commit."
wait_for_release_ci "$release_sha"

cd "$verification_dir"
curl -fsSLO "$release_base/$archive"
curl -fsSLO "$release_base/$dmg"
curl -fsSLO "$release_base/$checksums"
shasum -a 256 -c "$checksums"
pass "Fresh downloads match the published SHA-256 file"

mkdir extracted
ditto -x -k "$archive" extracted
app="extracted/Cairn.app"
[[ -d "$app" ]] || fail "$archive does not contain Cairn.app."

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$app_version" == "$VERSION" ]] || \
  fail "Downloaded App version is $app_version, expected $VERSION."
if [[ -n "$EXPECTED_BUILD" && "$app_build" != "$EXPECTED_BUILD" ]]; then
  fail "Downloaded App build is $app_build, expected $EXPECTED_BUILD."
fi
codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
pass "Downloaded App signature, ticket, Gatekeeper, and version $app_version ($app_build)"

xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
pass "Downloaded DMG ticket and Gatekeeper"

curl -fsSL -o /dev/null \
  "https://github.com/$GITHUB_REPOSITORY/releases/latest/download/$archive"
curl -fsSL -o /dev/null \
  "https://github.com/$GITHUB_REPOSITORY/releases/latest/download/$dmg"
pass "Latest-download routes resolve"

curl -fsSL -o /dev/null "$WEBSITE_URL"
pass "Website is reachable: $WEBSITE_URL"

release_url="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
printf '\nVerified Cairn %s from public downloads\n' "$VERSION"
printf 'Release: %s\n' "$release_url"
