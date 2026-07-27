#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MODE="${1:-source}"
VERSION=""
GITHUB_REPOSITORY="${CAIRN_GITHUB_REPOSITORY:-quentinzhang/cairn}"
SIGN_IDENTITY="${CAIRN_SIGN_IDENTITY:-Developer ID Application: Yue Zhang (JFF5GV3L69)}"
NOTARY_LOG="$(mktemp "${TMPDIR:-/tmp}/cairn-notary-preflight.XXXXXX")"

cleanup() {
  /bin/rm -f "$NOTARY_LOG"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: preflight.sh [source|credentials|release] [options]

  source                    Read-only repository checks; dirty work is reported.
  credentials               Validate Developer ID and notarization credentials.
  release                   Require clean, synchronized main, green CI, and auth.

Options:
  --version <semver>        Required in release mode.
  --repo <owner/name>       GitHub repository (default: quentinzhang/cairn).
  --help

Authentication:
  CAIRN_NOTARY_PROFILE      Keychain-profile mode.
  ASC_KEY_PATH              Team API Key .p8 path.
  ASC_KEY_ID                Team API Key ID.
  ASC_ISSUER_ID             Team Issuer UUID.
EOF
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

info() {
  printf 'INFO: %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

report_notary_error() {
  local mode="$1"
  local lower
  lower="$(tr '[:upper:]' '[:lower:]' < "$NOTARY_LOG")"

  if [[ "$lower" == *"401"* || "$lower" == *"unauthorized"* || "$lower" == *"invalid credential"* ]]; then
    warn "Apple rejected the credentials. Check for a revoked key or a mixed .p8, Key ID, and Issuer ID."
    warn "Individual App Store Connect API Keys cannot use notaryTool; direct mode requires a Team API Key."
  elif [[ "$lower" == *"403"* || "$lower" == *"forbidden"* ]]; then
    warn "Apple accepted the credential shape but denied access. Check the Team Key role, team membership, and pending agreements."
  elif [[ "$lower" == *"keychain"* && "$lower" == *"not found"* ]]; then
    warn "The keychain profile was not found in the active keychain. Confirm the profile name and keychain."
  elif [[ "$lower" == *"issuer"* ]]; then
    warn "The Team Issuer ID is missing or invalid. Copy the UUID from App Store Connect Team Keys."
  else
    warn "notarytool could not validate the $mode credentials."
  fi

  info "Sanitized notarytool output:"
  tail -n 20 "$NOTARY_LOG" |
    while IFS= read -r line; do
      if [[ -n "${ASC_KEY_PATH:-}" ]]; then
        line="${line//$ASC_KEY_PATH/<ASC_KEY_PATH>}"
      fi
      if [[ -n "${ASC_KEY_ID:-}" ]]; then
        line="${line//$ASC_KEY_ID/<ASC_KEY_ID>}"
      fi
      if [[ -n "${ASC_ISSUER_ID:-}" ]]; then
        line="${line//$ASC_ISSUER_ID/<ASC_ISSUER_ID>}"
      fi
      printf '  %s\n' "$line"
    done
}

validate_credentials() {
  require_command security
  require_command xcrun

  if ! security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" >/dev/null; then
    fail "Developer ID signing identity is unavailable: $SIGN_IDENTITY"
  fi
  pass "Developer ID signing identity is available"

  if [[ -n "${CAIRN_NOTARY_PROFILE:-}" ]]; then
    if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
      fail "Both credential modes are configured. Choose CAIRN_NOTARY_PROFILE or ASC_KEY_*, not both."
    fi
    if xcrun notarytool history \
      --keychain-profile "$CAIRN_NOTARY_PROFILE" \
      --output-format json >"$NOTARY_LOG" 2>&1; then
      pass "notarytool keychain profile is valid: $CAIRN_NOTARY_PROFILE"
      return
    fi
    report_notary_error "keychain-profile"
    fail "Notarization credential preflight failed"
  fi

  if [[ -z "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
    fail "Set CAIRN_NOTARY_PROFILE or the complete Team API Key tuple: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID."
  fi

  local missing=()
  [[ -n "${ASC_KEY_PATH:-}" ]] || missing+=("ASC_KEY_PATH")
  [[ -n "${ASC_KEY_ID:-}" ]] || missing+=("ASC_KEY_ID")
  [[ -n "${ASC_ISSUER_ID:-}" ]] || missing+=("ASC_ISSUER_ID")
  if (( ${#missing[@]} > 0 )); then
    if [[ " ${missing[*]} " == *" ASC_ISSUER_ID "* ]]; then
      warn "ASC_ISSUER_ID is required because direct notarization needs a Team API Key."
      warn "Individual App Store Connect API Keys cannot use notaryTool."
    fi
    fail "Incomplete Team API Key configuration; missing: ${missing[*]}"
  fi

  [[ "$ASC_KEY_PATH" == /* ]] || fail "ASC_KEY_PATH must be an absolute path."
  [[ -f "$ASC_KEY_PATH" ]] || fail "ASC_KEY_PATH does not point to a file."
  [[ -r "$ASC_KEY_PATH" ]] || fail "ASC_KEY_PATH is not readable."
  [[ "$ASC_KEY_ID" =~ ^[[:alnum:]]{10,}$ ]] || \
    fail "ASC_KEY_ID must be at least 10 alphanumeric characters."
  [[ "$ASC_ISSUER_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || \
    fail "ASC_ISSUER_ID must be a UUID."
  grep -q '^-----BEGIN PRIVATE KEY-----$' "$ASC_KEY_PATH" || \
    fail "ASC_KEY_PATH is not a PEM private key."
  grep -q '^-----END PRIVATE KEY-----$' "$ASC_KEY_PATH" || \
    fail "ASC_KEY_PATH is not a complete PEM private key."

  if [[ "$(basename "$ASC_KEY_PATH")" != "AuthKey_${ASC_KEY_ID}.p8" ]]; then
    warn "The .p8 filename does not match AuthKey_<ASC_KEY_ID>.p8; confirm the key and ID belong together."
  fi
  local key_permissions
  key_permissions="$(stat -f '%Lp' "$ASC_KEY_PATH")"
  if [[ "${key_permissions: -2}" != "00" ]]; then
    warn "The .p8 file permissions are $key_permissions; prefer owner-only access such as 600."
  fi

  if xcrun notarytool history \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --output-format json >"$NOTARY_LOG" 2>&1; then
    pass "App Store Connect Team API Key is valid for notarytool"
    return
  fi

  report_notary_error "Team API Key"
  fail "Notarization credential preflight failed"
}

source_checks() {
  [[ -d "$ROOT_DIR/.git" ]] || fail "Not a Git repository: $ROOT_DIR"
  [[ -f "$ROOT_DIR/Resources/Info.plist" ]] || fail "Missing Resources/Info.plist"
  [[ -x "$ROOT_DIR/Scripts/release.sh" ]] || fail "Scripts/release.sh is missing or not executable"
  [[ -x "$ROOT_DIR/Scripts/package_release.sh" ]] || fail "Scripts/package_release.sh is missing or not executable"
  [[ -f "$ROOT_DIR/.github/workflows/ci.yml" ]] || fail "Missing GitHub CI workflow"

  cd "$ROOT_DIR"
  for command_name in git bash zsh /usr/libexec/PlistBuddy; do
    require_command "$command_name"
  done

  zsh -n Scripts/build_app.sh Scripts/package_release.sh Scripts/release.sh
  bash -n \
    .agents/skills/cairn-release/scripts/preflight.sh \
    .agents/skills/cairn-release/scripts/verify_release.sh
  pass "Release script syntax"

  git diff --check
  git diff --cached --check
  pass "Git whitespace checks"

  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    fail "Repository has unresolved merge conflicts"
  fi
  pass "No merge conflicts"

  local tracked_sensitive
  tracked_sensitive="$(git ls-files | grep -E '(^|/)(\.env($|\.)|[^/]+\.(p8|p12|cer|mobileprovision|xcarchive|dmg|zip))$' || true)"
  if [[ -n "$tracked_sensitive" ]]; then
    printf '%s\n' "$tracked_sensitive" >&2
    fail "Credentials or release archives are tracked"
  fi
  pass "No tracked credentials or release archives"

  local untracked_sensitive
  untracked_sensitive="$(git ls-files --others --exclude-standard | grep -E '(^|/)(\.env($|\.)|[^/]+\.(p8|p12|cer|mobileprovision|xcarchive|dmg|zip))$' || true)"
  if [[ -n "$untracked_sensitive" ]]; then
    printf '%s\n' "$untracked_sensitive" >&2
    fail "Untracked credentials or release archives are inside the repository"
  fi
  pass "No untracked credentials or release archives"

  local current_version current_build branch origin
  current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
  current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
  [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "CFBundleShortVersionString is not semantic X.Y.Z."
  [[ "$current_build" =~ ^[0-9]+$ ]] || fail "CFBundleVersion is not numeric."
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  origin="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$branch" ]] || fail "Detached HEAD is not allowed"
  [[ -n "$origin" ]] || fail "Missing origin remote"

  info "Version: $current_version ($current_build)"
  info "Branch: $branch"
  info "Origin: $origin"
  info "Working tree summary:"
  git status --short
}

shift || true
while (( $# > 0 )); do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --repo)
      GITHUB_REPOSITORY="${2:-}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  --help)
    usage
    ;;
  source)
    source_checks
    pass "Cairn source preflight completed"
    ;;
  credentials)
    validate_credentials
    pass "Cairn credential preflight completed"
    ;;
  release)
    source_checks
    cd "$ROOT_DIR"

    [[ -n "$VERSION" ]] || fail "--version is required in release mode."
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version must be semantic X.Y.Z."
    [[ "$(git branch --show-current)" == "main" ]] || fail "Production releases must start on main."
    [[ -z "$(git status --porcelain)" ]] || fail "Production releases require a clean working tree."

    for command_name in gh swift node /usr/bin/python3 codesign security spctl ditto hdiutil shasum xcrun; do
      require_command "$command_name"
    done
    pass "Release toolchain is available"

    gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."
    [[ "$(gh repo view "$GITHUB_REPOSITORY" --json visibility --jq .visibility)" == "PUBLIC" ]] || \
      fail "$GITHUB_REPOSITORY is not public."
    origin_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    [[ "${origin_repository,,}" == "${GITHUB_REPOSITORY,,}" ]] || \
      fail "Origin resolves to $origin_repository, expected $GITHUB_REPOSITORY."

    git fetch --quiet origin main --tags
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
      fail "Local main does not match origin/main."

    head_sha="$(git rev-parse HEAD)"
    ci_state="$(gh run list \
      --repo "$GITHUB_REPOSITORY" \
      --workflow ci.yml \
      --commit "$head_sha" \
      --limit 1 \
      --json status,conclusion \
      --jq 'if length == 0 then "missing" else "\(.[0].status):\(.[0].conclusion)" end')"
    [[ "$ci_state" == "completed:success" ]] || fail "CI for $head_sha is $ci_state."
    pass "GitHub CI succeeded for $head_sha"

    latest_tag="$(gh release view --repo "$GITHUB_REPOSITORY" --json tagName --jq .tagName)"
    latest_version="${latest_tag#v}"
    version_order="$(/usr/bin/python3 - "$VERSION" "$latest_version" <<'PY'
import sys
candidate = tuple(map(int, sys.argv[1].split(".")))
latest = tuple(map(int, sys.argv[2].split(".")))
print("newer" if candidate > latest else "not-newer")
PY
)"
    [[ "$version_order" == "newer" ]] || \
      fail "$VERSION must be newer than the latest public release $latest_tag."
    pass "$VERSION is newer than $latest_tag"

    tag="v$VERSION"
    ! git rev-parse "$tag" >/dev/null 2>&1 || fail "Local tag already exists: $tag"
    ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || \
      fail "Remote tag already exists: $tag"
    ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || \
      fail "GitHub Release already exists: $tag"
    pass "$tag is available"

    validate_credentials
    pass "Cairn production-release preflight completed"
    ;;
  *)
    usage >&2
    fail "Unknown mode: $MODE"
    ;;
esac
