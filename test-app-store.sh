#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
derived_data_dir="${SLEEP_SWITCH_APP_STORE_BUILD_DIR:-$script_dir/build/app-store}"
app_dir="$derived_data_dir/Build/Products/Release/Sleep Switch.app"
executable="$app_dir/Contents/MacOS/Sleep Switch"
project_file="$script_dir/SleepSwitch.xcodeproj/project.pbxproj"

for source_file in "$script_dir/Sources/SleepSwitch/"*.swift; do
  source_name="${source_file:t}"
  if ! grep -Fq "$source_name in Sources" "$project_file"; then
    echo "The Xcode project is stale and does not compile $source_name."
    echo "Run: xcodegen generate --spec project.yml"
    exit 1
  fi
done

xcodebuild \
  -quiet \
  -project "$script_dir/SleepSwitch.xcodeproj" \
  -scheme SleepSwitch \
  -configuration Release \
  -derivedDataPath "$derived_data_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build

test -x "$executable"

executable_strings="$(strings -a "$executable")"
if grep -Eq \
  '/bin/ps|/usr/bin/pmset|pmset disablesleep|displaysleepnow|AppleSMC|fanhelper|FNum|F0Tg|Ftst|Cooling helper|Cooling Diagnostics' \
  <<<"$executable_strings"; then
  echo "App Store build contains a sandbox-incompatible command."
  exit 1
fi

test ! -e "$app_dir/Contents/Resources/SleepSwitchFanHelper"
test ! -d "$app_dir/Contents/Library/LaunchDaemons"

test "$(plutil -extract CFBundleIdentifier raw "$app_dir/Contents/Info.plist")" = \
  "lt.mantas.sleepswitch"
test "$(plutil -extract LSUIElement raw "$app_dir/Contents/Info.plist")" = "true"
test -f "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"

echo "SleepSwitch App Store build passed"
