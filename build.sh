#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="${SLEEP_SWITCH_BUILD_DIR:-$script_dir/build}"
app_dir="$build_dir/Sleep Switch.app"
arch_dir="$build_dir/arch"
helper_arch_dir="$build_dir/helper-arch"
asset_info_plist="$build_dir/asset-info.plist"
helper_executable="$app_dir/Contents/Resources/SleepSwitchFanHelper"
helper_plist_dir="$app_dir/Contents/Library/LaunchDaemons"
helper_plist_name="lt.mantas.sleepswitch.fanhelper.plist"
signing_identity="${SLEEP_SWITCH_SIGNING_IDENTITY:--}"
allow_development_signing="${SLEEP_SWITCH_ALLOW_DEVELOPMENT_SIGNING:-0}"
module_cache_dir="${CLANG_MODULE_CACHE_PATH:-$build_dir/module-cache}"
export CLANG_MODULE_CACHE_PATH="$module_cache_dir"

rm -rf "$app_dir" "$arch_dir" "$helper_arch_dir"
rm -f "$asset_info_plist"
mkdir -p \
  "$app_dir/Contents/MacOS" \
  "$app_dir/Contents/Resources" \
  "$helper_plist_dir" \
  "$arch_dir" \
  "$helper_arch_dir" \
  "$module_cache_dir"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp \
  "$script_dir/Config/FanHelper/$helper_plist_name" \
  "$helper_plist_dir/$helper_plist_name"
cp "$script_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework IOKit \
    -framework SwiftUI \
    -framework Charts \
    -framework Security \
    -framework ServiceManagement \
    -lsqlite3 \
    "$script_dir/Sources/SleepSwitch/"*.swift \
    "$script_dir/Sources/SleepSwitchFanProtocol/"*.swift \
    -o "$arch_dir/SleepSwitch-$arch"

  xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -framework IOKit \
    -framework Security \
    "$script_dir/Sources/SleepSwitch/CoolingTelemetry.swift" \
    "$script_dir/Sources/SleepSwitchFanProtocol/"*.swift \
    "$script_dir/Sources/SleepSwitchFanHelper/"*.swift \
    -o "$helper_arch_dir/SleepSwitchFanHelper-$arch"
done

xcrun lipo -create \
  "$arch_dir/SleepSwitch-arm64" \
  "$arch_dir/SleepSwitch-x86_64" \
  -output "$app_dir/Contents/MacOS/SleepSwitch"

xcrun lipo -create \
  "$helper_arch_dir/SleepSwitchFanHelper-arm64" \
  "$helper_arch_dir/SleepSwitchFanHelper-x86_64" \
  -output "$helper_executable"

xcrun actool \
  "$script_dir/AppStore/Assets.xcassets" \
  --compile "$app_dir/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$asset_info_plist" \
  >/dev/null

xattr -cr "$app_dir"
# Finder metadata can be reattached to bundles when the repository is hosted
# in a synced folder. It makes an otherwise valid signature fail closed.
xattr -r -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -r -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
helper_sign_arguments=(
  --force
  --options runtime
  --identifier lt.mantas.sleepswitch.fanhelper
  --sign "$signing_identity"
)
app_sign_arguments=(
  --force
  --options runtime
  --identifier lt.mantas.sleepswitch
  --entitlements "$script_dir/Config/Direct/SleepSwitch.entitlements"
  --sign "$signing_identity"
)
if [[ "$signing_identity" != "-" ]]; then
  helper_sign_arguments+=(--timestamp)
  app_sign_arguments+=(--timestamp)
fi

codesign "${helper_sign_arguments[@]}" "$helper_executable"
codesign "${app_sign_arguments[@]}" "$app_dir"

if [[ "$signing_identity" != "-" ]]; then
  helper_team_identifier="$(
    codesign -dvvv "$helper_executable" 2>&1 \
      | sed -n 's/^TeamIdentifier=//p'
  )"
  app_team_identifier="$(
    codesign -dvvv "$app_dir" 2>&1 \
      | sed -n 's/^TeamIdentifier=//p'
  )"
  helper_authority="$(
    codesign -dvvv "$helper_executable" 2>&1 \
      | awk -F= '$1 == "Authority" && !seen { print substr($0, 11); seen = 1 }'
  )"
  app_authority="$(
    codesign -dvvv "$app_dir" 2>&1 \
      | awk -F= '$1 == "Authority" && !seen { print substr($0, 11); seen = 1 }'
  )"
  if [[ "$helper_team_identifier" != "C43F5MKJF2" \
     || "$app_team_identifier" != "C43F5MKJF2" ]]; then
    echo "The app and helper must be signed by team C43F5MKJF2."
    exit 1
  fi
  if [[ "$helper_authority" == "Developer ID Application:"* \
     && "$app_authority" == "Developer ID Application:"* ]]; then
    :
  elif [[ "$helper_authority" == "Apple Development:"* \
       && "$app_authority" == "Apple Development:"* \
       && "$allow_development_signing" == "1" ]]; then
    :
  else
    echo "The app and helper require matching Developer ID Application signatures."
    echo "For a local build, set SLEEP_SWITCH_ALLOW_DEVELOPMENT_SIGNING=1 to accept matching Apple Development signatures."
    exit 1
  fi
else
  echo "Note: ad-hoc builds cannot register the signed cooling helper."
fi

codesign --verify --deep --strict "$app_dir"
plutil -lint "$helper_plist_dir/$helper_plist_name" >/dev/null
echo "$app_dir"
