#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
derived_data_dir="${SLEEP_SWITCH_APP_STORE_BUILD_DIR:-$script_dir/build/app-store}"
app_dir="$derived_data_dir/Build/Products/Release/Sleep Switch.app"
executable="$app_dir/Contents/MacOS/Sleep Switch"

xcodebuild \
  -quiet \
  -project "$script_dir/SleepSwitch.xcodeproj" \
  -scheme SleepSwitch \
  -configuration Release \
  -derivedDataPath "$derived_data_dir" \
  CODE_SIGNING_ALLOWED=NO \
  build

test -x "$executable"

if strings "$executable" | grep -Eq '/bin/ps|/usr/bin/pmset|displaysleepnow'; then
  echo "App Store build contains a sandbox-incompatible command."
  exit 1
fi

test "$(plutil -extract CFBundleIdentifier raw "$app_dir/Contents/Info.plist")" = \
  "lt.mantas.sleepswitch"
test "$(plutil -extract LSUIElement raw "$app_dir/Contents/Info.plist")" = "true"
test -f "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"

echo "SleepSwitch App Store build passed"
