#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
test_dir="$script_dir/build/tests"
test_binary="$test_dir/AgentTrackerTests"

mkdir -p "$test_dir"

xcrun swiftc \
  -parse-as-library \
  -framework AppKit \
  -framework IOKit \
  "$script_dir/Sources/SleepSwitch/AgentTracker.swift" \
  "$script_dir/Sources/SleepSwitch/AwakeSession.swift" \
  "$script_dir/Sources/SleepSwitch/CodexSessionTracker.swift" \
  "$script_dir/Sources/SleepSwitch/DisplayPowerController.swift" \
  "$script_dir/Sources/SleepSwitch/PowerAssertionController.swift" \
  "$script_dir/Tests/AgentTrackerTests.swift" \
  -o "$test_binary"

"$test_binary"
