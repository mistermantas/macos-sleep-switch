#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="$script_dir/build"
app_dir="$build_dir/Sleep Switch.app"
arch_dir="$build_dir/arch"
iconset_dir="$build_dir/AppIcon.iconset"

rm -rf "$app_dir" "$arch_dir" "$iconset_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$arch_dir" "$iconset_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework ServiceManagement \
    "$script_dir/Sources/SleepSwitch/"*.swift \
    -o "$arch_dir/SleepSwitch-$arch"
done

xcrun lipo -create \
  "$arch_dir/SleepSwitch-arm64" \
  "$arch_dir/SleepSwitch-x86_64" \
  -output "$app_dir/Contents/MacOS/SleepSwitch"

sips -s format png "$script_dir/Assets/AppIcon.svg" --out "$build_dir/AppIcon.png" >/dev/null
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" \
            "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" \
            "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" \
            "1024:icon_512x512@2x.png"; do
  size="${spec%%:*}"
  name="${spec#*:}"
  sips -z "$size" "$size" "$build_dir/AppIcon.png" --out "$iconset_dir/$name" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app_dir"
echo "$app_dir"
