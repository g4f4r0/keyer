#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_bundle="$project_root/build/Release/Keyer.app"
executable="$project_root/.build/arm64-apple-macosx/release/Keyer"
fluid_audio_resources="$project_root/.build/arm64-apple-macosx/release/FluidAudio_FluidAudio.bundle"
release_directory="$project_root/build/Release"

cd "$project_root"

swift test -c release -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors

mkdir -p "$release_directory"
staging_directory=$(mktemp -d "$release_directory/.keyer-stage.XXXXXX")
staged_app="$staging_directory/Keyer.app"
trap 'rm -rf "$staging_directory"' EXIT

mkdir -p "$staged_app/Contents/MacOS"
mkdir -p "$staged_app/Contents/Resources"
cp "$executable" "$staged_app/Contents/MacOS/Keyer"
cp "$project_root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
cp -R "$project_root/Resources/RemixIcons" "$staged_app/Contents/Resources/RemixIcons"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$staged_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$project_root/Resources/Licenses" "$staged_app/Contents/Resources/Licenses"
[[ -d "$fluid_audio_resources" ]] || { print -u2 "Missing FluidAudio resource bundle: $fluid_audio_resources"; exit 1; }
cp -R "$fluid_audio_resources" "$staged_app/Contents/Resources/FluidAudio_FluidAudio.bundle"

icon_source="$project_root/Resources/KeyerIcon.png"
iconset="$staging_directory/AppIcon.iconset"
[[ -f "$icon_source" ]] || { print -u2 "Missing app icon master: $icon_source"; exit 1; }
mkdir -p "$iconset"
sips -s format png -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "$icon_source" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" -o "$staged_app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

plutil -replace CFBundleExecutable -string Keyer "$staged_app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.keyer.app "$staged_app/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$staged_app/Contents/Info.plist"

signing_line=$(security find-identity -v -p codesigning | sed -n '/"Apple Development:/p' | head -n 1)
signing_identity=$(print -r -- "$signing_line" | sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development:.*/\1/p')
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  print "No Apple Development identity found; using ad-hoc signing. Privacy grants may reset after rebuilds."
fi

codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$project_root/Resources/Keyer.entitlements" \
  "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

# Never mutate a signed executable while macOS may still have its pages mapped.
# Doing so can terminate the running app with CODESIGNING/Invalid Page.
running_executable="$app_bundle/Contents/MacOS/Keyer"
running_pattern="^${running_executable}( |$)"
while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill "$pid"
done < <(pgrep -f "$running_pattern" 2>/dev/null || true)

for _ in {1..100}; do
  if ! pgrep -f "$running_pattern" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

if pgrep -f "$running_pattern" >/dev/null 2>&1; then
  print -u2 "Keyer did not quit; leaving the existing signed bundle untouched."
  exit 1
fi

if [[ -e "$app_bundle" ]]; then
  [[ "$app_bundle" == "$project_root/build/Release/Keyer.app" ]] || exit 1
  rm -rf "$app_bundle"
fi
mv "$staged_app" "$app_bundle"
rm -rf "$staging_directory"
trap - EXIT
codesign --verify --deep --strict --verbose=2 "$app_bundle"

print "Built: $app_bundle"
