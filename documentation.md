# Sleep Switch operator runbook

## What it is

Sleep Switch is a macOS menu-bar app with a private-iCloud iPhone companion. The Mac observes local agent sessions, power and cooling telemetry, and executes all power/awake actions. The iPhone shows a compact status, sends expiring remote commands, and publishes cached app-group data for widgets.

## Local setup and verification

Run from the repository root:

```zsh
./test.sh
./test-direct.sh
xcodebuild -project SleepSwitch.xcodeproj -scheme SleepSwitchCompanion -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Generate the Xcode project after editing `project.yml`:

```zsh
xcodegen generate
```

## Demo recipes

- **Thermals:** while the companion is foregrounded, it refetches Mac status every 15 seconds. Open a paired Mac, select a cooling profile, and verify the temperature/fan timestamp advances as the Mac publishes status.
- **Widgets:** add any of the overview, battery, thermal, fan, agents, power, or connection widgets. Choose a paired Mac, hide its name if desired, then check that the focused value comes from the cached app-group snapshot.
- **Agent finish action:** queue sleep or shutdown on the Mac or iPhone while agents are active. The one-shot request waits for the final session to end, holds for 15 seconds, and cancels if an agent starts again in that window.

## Important architecture

- `Sources/SleepSwitch/CompanionMacBridge.swift`: Mac status/history publication and command polling.
- `Sources/SleepSwitch/CompanionProtocol.swift`: shared remote command and status model.
- `Sources/SleepSwitchCompanion/`: iPhone dashboard, CloudKit client, notifications, Live Activity.
- `Sources/SleepSwitchCompanionWidgets/`: WidgetKit extensions.
- `Sources/Shared/CompanionWidgetShared.swift`: app-group snapshot shared by the iPhone app and widgets.

## Release notes

iOS build 30 is valid in App Store Connect. Builds 31 and 32 are reserved for follow-up releases; build 32 is the thermal-refresh, finish-actions, and widget-family archive. New uploads authenticate with the supplied App Store Connect API key; never place that `.p8` file in the repository.

The local keychain currently has Apple Development identities only. An iOS 2.4.0 (32) archive can be produced, but App Store export stops at `Failed to Use Accounts` because no iOS Distribution identity is available. macOS App Store export separately requires Mac App Distribution and Mac Installer Distribution identities. Do not use an Apple Development-signed archive as a substitute.
