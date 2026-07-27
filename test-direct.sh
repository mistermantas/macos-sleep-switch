#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
build_dir="${SLEEP_SWITCH_DIRECT_TEST_BUILD_DIR:-$script_dir/build/direct-test}"
app_dir="${SLEEP_SWITCH_DIRECT_APP:-$build_dir/Sleep Switch.app}"
main_executable="$app_dir/Contents/MacOS/SleepSwitch"
helper_executable="$app_dir/Contents/Resources/SleepSwitchFanHelper"
daemon_plist="$app_dir/Contents/Library/LaunchDaemons/lt.mantas.sleepswitch.fanhelper.plist"

if [[ ! -x "$main_executable" || ! -x "$helper_executable" ]]; then
  SLEEP_SWITCH_BUILD_DIR="$build_dir" "$script_dir/build.sh" >/dev/null
fi

test -x "$main_executable"
test -x "$helper_executable"
test -f "$daemon_plist"
test -f "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"

test "$(plutil -extract CFBundleIdentifier raw "$app_dir/Contents/Info.plist")" = \
  "lt.mantas.sleepswitch"
test "$(plutil -extract BundleProgram raw "$daemon_plist")" = \
  "Contents/Resources/SleepSwitchFanHelper"
test "$(plutil -extract MachServices.lt\\.mantas\\.sleepswitch\\.fanhelper raw "$daemon_plist")" = \
  "true"

codesign --verify --deep --strict --verbose=4 "$app_dir"

main_signature="$(codesign -dvvv "$app_dir" 2>&1)"
helper_signature="$(codesign -dvvv "$helper_executable" 2>&1)"
grep -q '^Identifier=lt.mantas.sleepswitch$' <<<"$main_signature"
grep -q '^Identifier=lt.mantas.sleepswitch.fanhelper$' <<<"$helper_signature"
grep -q 'flags=.*runtime' <<<"$main_signature"
grep -q 'flags=.*runtime' <<<"$helper_signature"

main_architectures="$(lipo -archs "$main_executable")"
helper_architectures="$(lipo -archs "$helper_executable")"
grep -qw arm64 <<<"$main_architectures"
grep -qw x86_64 <<<"$main_architectures"
grep -qw arm64 <<<"$helper_architectures"
grep -qw x86_64 <<<"$helper_architectures"

main_strings="$(strings -a "$main_executable")"
helper_strings="$(strings -a "$helper_executable")"

if ! grep -q 'Sleep Switch Cooling Diagnostics' <<<"$main_strings"; then
  echo "The direct app is missing its anonymized cooling diagnostic export."
  exit 1
fi

if grep -Eq 'AppleSMC|FNum|F0Tg|Ftst' <<<"$main_strings"; then
  echo "The ordinary app executable contains privileged SMC implementation strings."
  exit 1
fi

for required_helper_string in AppleSMC FNum Ftst auxiliary-sensors=; do
  if ! grep -q "$required_helper_string" <<<"$helper_strings"; then
    echo "The helper is missing required implementation string: $required_helper_string"
    exit 1
  fi
done

protocol_source="$script_dir/Sources/SleepSwitchFanProtocol/FanHelperMessages.swift"
protocol_surface="$(
  sed -n '/@objc protocol FanHelperProtocol/,/^}/p' "$protocol_source"
)"
if grep -Eqi 'forKey|smcKey|targetRPM|rawRPM|priority' <<<"$protocol_surface"; then
  echo "The privileged protocol exposes a raw hardware-control primitive."
  exit 1
fi

if [[ "${SLEEP_SWITCH_REQUIRE_DISTRIBUTION_SIGNATURE:-0}" == "1" ]]; then
  main_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$main_signature")"
  helper_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_signature")"
  test "$main_team" = "C43F5MKJF2"
  test "$helper_team" = "C43F5MKJF2"
  ! grep -q 'Signature=adhoc' <<<"$main_signature"
  ! grep -q 'Signature=adhoc' <<<"$helper_signature"
  grep -q '^Authority=Developer ID Application:' <<<"$main_signature"
  grep -q '^Authority=Developer ID Application:' <<<"$helper_signature"
  spctl --assess --type execute --verbose=4 "$app_dir"
  xcrun stapler validate "$app_dir"
fi

echo "SleepSwitch direct build passed"
