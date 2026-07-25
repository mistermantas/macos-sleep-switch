#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="${SLEEP_SWITCH_BUILD_DIR:-$script_dir/build}"
app_dir="$build_dir/Sleep Switch.app"
arch_dir="$build_dir/arch"
asset_info_plist="$build_dir/asset-info.plist"

rm -rf "$app_dir" "$arch_dir"
rm -f "$asset_info_plist"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$arch_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework IOKit \
    -framework ServiceManagement \
    "$script_dir/Sources/SleepSwitch/"*.swift \
    -o "$arch_dir/SleepSwitch-$arch"
done

xcrun lipo -create \
  "$arch_dir/SleepSwitch-arm64" \
  "$arch_dir/SleepSwitch-x86_64" \
  -output "$app_dir/Contents/MacOS/SleepSwitch"

xcrun actool \
  "$script_dir/AppStore/Assets.xcassets" \
  --compile "$app_dir/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$asset_info_plist" \
  >/dev/null

xattr -cr "$app_dir"
codesign --force --sign - "$app_dir"
echo "$app_dir"
