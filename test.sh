#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_dir="$script_dir/build/tests"
test_binary="$test_dir/AgentTrackerTests"
install_script="$script_dir/install-local.sh"
module_cache_dir="${CLANG_MODULE_CACHE_PATH:-$test_dir/module-cache}"
export CLANG_MODULE_CACHE_PATH="$module_cache_dir"

mkdir -p "$test_dir" "$module_cache_dir"

/bin/zsh -n "$install_script"
for fragment in \
  'SleepDisabled" && !found { print $2' \
  'SLEEP_SWITCH_REQUIRE_DISTRIBUTION_SIGNATURE=1' \
  'pgrep -x SleepSwitch' \
  'system/lt.mantas.sleepswitch.fanhelper' \
  'Use --replace' \
  'Sleep Switch.backup.'; do
  if ! /usr/bin/grep -Fq "$fragment" "$install_script"; then
    echo "Safe installer is missing guard: $fragment"
    exit 1
  fi
done
if /usr/bin/grep -Eq \
  '(^|[[:space:]])(/usr/bin/)?sudo([[:space:]]|$)' \
  "$install_script"; then
  echo "Safe installer must not invoke sudo."
  exit 1
fi

xcrun swiftc \
  -parse-as-library \
  -framework AppKit \
  -framework IOKit \
  -framework Security \
  "$script_dir/Sources/SleepSwitch/AgentTracker.swift" \
  "$script_dir/Sources/SleepSwitch/AppDistribution.swift" \
  "$script_dir/Sources/SleepSwitch/AppLinks.swift" \
  "$script_dir/Sources/SleepSwitch/AwakeSession.swift" \
  "$script_dir/Sources/SleepSwitch/CodexSessionTracker.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingProfile.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingPolicy.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingTelemetry.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingDiagnostics.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingCoordinator.swift" \
  "$script_dir/Sources/SleepSwitch/DisplayPowerController.swift" \
  "$script_dir/Sources/SleepSwitch/PowerAssertionController.swift" \
  "$script_dir/Sources/SleepSwitch/ProcessInfoThermalMonitor.swift" \
  "$script_dir/Sources/SleepSwitch/FanHelperClient.swift" \
  "$script_dir/Sources/SleepSwitchFanProtocol/FanHelperMessages.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanHardwareFixture.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanHardwareControlling.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanHardwareController.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanClientValidator.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanHelperService.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanLeaseManager.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/FanLeaseWatchdog.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/ExternalFanControllerDetector.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/SystemPowerObserver.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/SMCConnection.swift" \
  "$script_dir/Sources/SleepSwitchFanHelper/TemperatureMonitor.swift" \
  "$script_dir/Tests/AgentTrackerTests.swift" \
  "$script_dir/Tests/CoolingPolicyTests.swift" \
  "$script_dir/Tests/FanHardwareFixtureTests.swift" \
  "$script_dir/Tests/FanHardwareControllerTests.swift" \
  "$script_dir/Tests/FanLeaseManagerTests.swift" \
  "$script_dir/Tests/FanHelperSecurityTests.swift" \
  "$script_dir/Tests/CoolingCoordinatorTests.swift" \
  "$script_dir/Tests/CoolingDiagnosticsTests.swift" \
  -o "$test_binary"

"$test_binary"
