#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
master="$root/Resources/AppIcon-1024.png"
icon_workspace=$(mktemp -d "${TMPDIR:-/tmp}/cairn-icon.XXXXXX")
iconset_dir="$icon_workspace/Cairn.iconset"
mkdir -p "$iconset_dir"
trap '/bin/rm -rf "$icon_workspace"' EXIT

swift "$root/Scripts/generate_app_icon.swift" "$master"

for specification in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size=${specification%% *}
  filename=${specification#* }
  sips -z "$size" "$size" "$master" --out "$iconset_dir/$filename" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$root/Resources/AppIcon.icns"
echo "Generated $root/Resources/AppIcon.icns"
