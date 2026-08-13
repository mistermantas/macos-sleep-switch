#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project="$script_dir/SleepSwitch.xcodeproj"

production_entitlements=(
  "$script_dir/AppStore/SleepSwitch.entitlements"
  "$script_dir/Companion/SleepSwitchCompanion.entitlements"
  "$script_dir/Config/Direct/SleepSwitch.entitlements"
)
debug_entitlements=(
  "$script_dir/AppStore/SleepSwitch.Debug.entitlements"
  "$script_dir/Companion/SleepSwitchCompanion.Debug.entitlements"
)

for entitlements in "${production_entitlements[@]}"; do
  test -f "$entitlements"
  environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$entitlements")"
  if [[ "$environment" != "Production" ]]; then
    echo "Distribution entitlement is not Production: $entitlements"
    exit 1
  fi
done

for entitlements in "${debug_entitlements[@]}"; do
  test -f "$entitlements"
  environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$entitlements")"
  if [[ "$environment" != "Development" ]]; then
    echo "Debug entitlement is not Development: $entitlements"
    exit 1
  fi
done

release_settings="$(xcodebuild -project "$project" -scheme SleepSwitch -configuration Release -showBuildSettings 2>/dev/null)"
companion_release_settings="$(xcodebuild -project "$project" -scheme SleepSwitchCompanion -configuration Release -showBuildSettings 2>/dev/null)"
grep -Fq "CODE_SIGN_ENTITLEMENTS = AppStore/SleepSwitch.entitlements" <<<"$release_settings"
grep -Fq "CODE_SIGN_ENTITLEMENTS = Companion/SleepSwitchCompanion.entitlements" <<<"$companion_release_settings"

if [[ -n "${SLEEP_SWITCH_DISTRIBUTION_APP:-}" ]]; then
  app="${SLEEP_SWITCH_DISTRIBUTION_APP}"
  test -d "$app"
  signed_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
  grep -Fq "<string>Production</string>" <<<"$signed_entitlements"
  codesign --verify --deep --strict "$app"
fi

echo "Sleep Switch distribution configuration passed"
