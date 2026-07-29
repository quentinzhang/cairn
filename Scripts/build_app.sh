#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
swift build -c release

app="$root/dist/Cairn.app"
entitlements="$root/Resources/Cairn.entitlements"
resource_bundle="$root/.build/release/Cairn_Cairn.bundle"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/cairn" "$app/Contents/MacOS/cairn"
# The bridges the agents run, and the installers that register them. Both sets
# have to be here: an app downloaded as a .dmg has no checkout beside it, so
# Connect drives these copies and every hook it writes points inside the
# bundle — which is also what makes a moved or deleted checkout harmless.
for script in \
  cairn_codex_hook.py \
  cairn_claude_hook.py \
  cairn_locator.py \
  cairn_save.py \
  cairn_payload.py \
  cairn_connect.py \
  cairn_doctor.py \
  cairn_reset.py \
  install_codex_hook.py \
  install_claude_hook.py \
  install_hermes_plugin.py \
  install_opencode_plugin.py \
  install_openclaw_plugin.py \
  install_agent_skills.py
do
  cp "$root/Scripts/$script" "$app/Contents/Resources/$script"
done
/bin/rm -rf "$app/Contents/Resources/AgentSkills"
cp -R "$root/AgentSkills" "$app/Contents/Resources/AgentSkills"
/bin/rm -rf "$app/Contents/Resources/HermesPlugin" "$app/Contents/Resources/OpenClawPlugin" "$app/Contents/Resources/OpenCodePlugin"
cp -R "$root/HermesPlugin" "$app/Contents/Resources/HermesPlugin"
cp -R "$root/OpenClawPlugin" "$app/Contents/Resources/OpenClawPlugin"
cp -R "$root/OpenCodePlugin" "$app/Contents/Resources/OpenCodePlugin"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
[[ -d "$resource_bundle" ]] || {
  echo "Error: Swift package resource bundle is missing: $resource_bundle" >&2
  exit 1
}
/bin/rm -rf "$app/Contents/Resources/Cairn_Cairn.bundle"
cp -R "$resource_bundle" "$app/Contents/Resources/Cairn_Cairn.bundle"
for locale in en zh-Hans ja; do
  source_lproj="$root/Sources/Cairn/Resources/$locale.lproj"
  destination_lproj="$app/Contents/Resources/$locale.lproj"
  mkdir -p "$destination_lproj"
  cp "$source_lproj/InfoPlist.strings" "$destination_lproj/InfoPlist.strings"
done
# A stable signing identity keeps TCC grants (Accessibility, Automation)
# valid across rebuilds; ad-hoc signatures change every build and macOS
# treats each one as a brand-new app. Override with CAIRN_SIGN_IDENTITY,
# set it to "-" for ad-hoc on machines without the certificate.
sign_identity="${CAIRN_SIGN_IDENTITY:-Developer ID Application: Yue Zhang (JFF5GV3L69)}"
if [[ "$sign_identity" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "$sign_identity"; then
  sign_identity="-"
fi
if [[ "$sign_identity" == "-" ]]; then
  codesign \
    --force \
    --deep \
    --entitlements "$entitlements" \
    --sign - \
    "$app" >/dev/null
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$entitlements" \
    --sign "$sign_identity" \
    "$app" >/dev/null
fi

codesign -d --entitlements :- "$app" 2>/dev/null |
  grep -q '<key>com.apple.security.automation.apple-events</key>' || {
    echo "Error: signed app is missing the Apple Events entitlement." >&2
    exit 1
  }

echo "Built $app (signed: $sign_identity)"
