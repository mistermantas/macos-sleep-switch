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
- **Widgets:** add a Sleep Switch widget, choose a paired Mac and a focused metric, then check it displays the cached app-group snapshot with a visible freshness state.
- **Agent finish action:** queue a finish action on the Mac or iPhone, start/finish an agent session, and confirm the action occurs only after the final session ends.

## Important architecture

- `Sources/SleepSwitch/CompanionMacBridge.swift`: Mac status/history publication and command polling.
- `Sources/SleepSwitch/CompanionProtocol.swift`: shared remote command and status model.
- `Sources/SleepSwitchCompanion/`: iPhone dashboard, CloudKit client, notifications, Live Activity.
- `Sources/SleepSwitchCompanionWidgets/`: WidgetKit extensions.
- `Sources/Shared/CompanionWidgetShared.swift`: app-group snapshot shared by the iPhone app and widgets.

## Release notes

iOS build 30 is valid in App Store Connect. Build 31 is reserved for the destructive-controls correction. New uploads authenticate with the supplied App Store Connect API key; never place that `.p8` file in the repository.

macOS App Store export currently requires Mac App Distribution and Mac Installer Distribution identities that are not present in this keychain. Do not use an Apple Development-signed archive as a substitute.
