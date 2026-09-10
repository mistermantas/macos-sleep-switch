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
/bin/zsh -n "$script_dir/verify-distribution.sh"
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

"$script_dir/verify-distribution.sh"

xcrun swiftc \
  -parse-as-library \
  -framework AppKit \
  -framework IOKit \
  -framework SwiftUI \
  -framework Charts \
  -framework CloudKit \
  -framework Network \
  -framework Security \
  -lsqlite3 \
  "$script_dir/Sources/SleepSwitch/AgentTracker.swift" \
  "$script_dir/Sources/SleepSwitch/AppDistribution.swift" \
  "$script_dir/Sources/SleepSwitch/AppLinks.swift" \
  "$script_dir/Sources/SleepSwitch/AwakeSession.swift" \
  "$script_dir/Sources/SleepSwitch/CodexSessionTracker.swift" \
  "$script_dir/Sources/SleepSwitch/OperatorModels.swift" \
  "$script_dir/Sources/SleepSwitch/RemoteWorkProjection.swift" \
  "$script_dir/Sources/SleepSwitch/RemoteWorkAttention.swift" \
  "$script_dir/Sources/SleepSwitch/CodexOperatorAdapter.swift" \
  "$script_dir/Sources/SleepSwitch/CodexThreadMirrorAdapter.swift" \
  "$script_dir/Sources/SleepSwitch/CodexThreadSectionController.swift" \
  "$script_dir/Sources/SleepSwitch/HermesOperatorAdapter.swift" \
  "$script_dir/Sources/SleepSwitch/OperatorStore.swift" \
  "$script_dir/Sources/SleepSwitch/OperatorSkillIndexer.swift" \
  "$script_dir/Sources/SleepSwitch/OperatorCoordinator.swift" \
  "$script_dir/Sources/SleepSwitch/HermesSessionTracker.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingProfile.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingPolicy.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingTelemetry.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingDiagnostics.swift" \
  "$script_dir/Sources/SleepSwitch/InsightsModels.swift" \
  "$script_dir/Sources/SleepSwitch/EnergyTelemetry.swift" \
  "$script_dir/Sources/SleepSwitch/HistoryStore.swift" \
  "$script_dir/Sources/SleepSwitch/InsightsRecorder.swift" \
  "$script_dir/Sources/SleepSwitch/InsightsWindowController.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionProtocol.swift" \
  "$script_dir/Sources/Shared/CompanionLiveActivityModels.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionLiveActivityProjection.swift" \
  "$script_dir/Sources/SleepSwitch/SystemLoadSampler.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionMachineFingerprint.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionOperatorModels.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionOperatorProjection.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionOperatorRequestHandler.swift" \
  "$script_dir/Sources/SleepSwitch/LocalPreviewSecurity.swift" \
  "$script_dir/Sources/SleepSwitch/LocalPreviewEndpoint.swift" \
  "$script_dir/Sources/SleepSwitch/NetworkAvailabilityMonitor.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionContextTransferHistory.swift" \
  "$script_dir/Sources/SleepSwitch/RemoteArtifactDownloadStore.swift" \
  "$script_dir/Sources/SleepSwitch/RemoteContextInbox.swift" \
  "$script_dir/Sources/Shared/SharedContextIntake.swift" \
  "$script_dir/Sources/Shared/CompanionWidgetShared.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionCloudStore.swift" \
  "$script_dir/Sources/SleepSwitch/CompanionMacBridge.swift" \
  "$script_dir/Sources/SleepSwitch/CoolingCoordinator.swift" \
  "$script_dir/Sources/SleepSwitch/DisplayPowerController.swift" \
  "$script_dir/Sources/SleepSwitch/PowerAssertionController.swift" \
  "$script_dir/Sources/SleepSwitch/SleepSwitchPreferences.swift" \
  "$script_dir/Sources/SleepSwitch/StatusBarAppearance.swift" \
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
  "$script_dir/Tests/OperatorAdapterTests.swift" \
  "$script_dir/Tests/CompanionOperatorTests.swift" \
  "$script_dir/Tests/RemoteWorkProjectionTests.swift" \
  "$script_dir/Tests/RemoteWorkAttentionTests.swift" \
  "$script_dir/Tests/CodexThreadMirrorAdapterTests.swift" \
  "$script_dir/Tests/CoolingPolicyTests.swift" \
  "$script_dir/Tests/FanHardwareFixtureTests.swift" \
  "$script_dir/Tests/FanHardwareControllerTests.swift" \
  "$script_dir/Tests/FanLeaseManagerTests.swift" \
  "$script_dir/Tests/FanHelperSecurityTests.swift" \
  "$script_dir/Tests/CoolingCoordinatorTests.swift" \
  "$script_dir/Tests/CoolingDiagnosticsTests.swift" \
  "$script_dir/Tests/InsightsHistoryTests.swift" \
  "$script_dir/Tests/CompanionProtocolTests.swift" \
  "$script_dir/Tests/CompanionLiveActivityTests.swift" \
  "$script_dir/Tests/LocalPreviewSecurityTests.swift" \
  "$script_dir/Tests/LocalPreviewEndpointTests.swift" \
  "$script_dir/Tests/RemoteContextInboxTests.swift" \
  "$script_dir/Tests/RemoteArtifactDownloadStoreTests.swift" \
  "$script_dir/Tests/SharedContextIntakeTests.swift" \
  "$script_dir/Tests/CompanionMacBridgeTests.swift" \
  -o "$test_binary"

"$test_binary"
