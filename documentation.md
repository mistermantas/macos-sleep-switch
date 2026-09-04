# Sleep Switch Operator runbook

## What Operator is

Operator is the read-only operations layer inside Sleep Switch. On the Mac it makes local agent sessions, skills, machine state, and existing automations observable in one place. On iPhone it sends only compact private-iCloud summaries and never executes a new control path.

## Privacy and ownership

- Harness adapters read whitelisted local metadata only. They do not retain prompts, tool payloads, credentials, or original task logs.
- The Operator database is local. It owns skill tags, favourites, and use counts.
- A source `SKILL.md` is never changed by Operator. Copy, reveal, export, and share happen only after a user action.
- iCloud summaries are bounded and private: live counts, safe token/duration deltas, machine state, alert state, and existing finish actions. They exclude raw skills, file paths, prompts, and event details.

## Current sources

- `Sources/SleepSwitch/CodexSessionTracker.swift` observes task activity from local Codex session logs.
- `Sources/SleepSwitch/HermesSessionTracker.swift` observes Hermes active leases.
- `Sources/SleepSwitch/AgentTracker.swift` remains responsible for awake-session detection; Operator adapters must not change that safety behavior.
- `Sources/SleepSwitch/CompanionProtocol.swift` and `CompanionMacBridge.swift` provide the existing private-CloudKit path.
- `Sources/SleepSwitch/OperatorModels.swift`, `OperatorStore.swift`, and `OperatorCoordinator.swift` hold the normalized local records, SQLite metadata database, and bounded refresh path.
- `Sources/SleepSwitch/CodexOperatorAdapter.swift` and `HermesOperatorAdapter.swift` whitelist lifecycle/token fields. Hermes never reads its message or FTS tables.
- `Sources/SleepSwitch/OperatorSkillIndexer.swift` indexes `SKILL.md` files without changing them.

## Local verification

Run from the repository root:

```zsh
./test.sh
./test-direct.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \\
  xcodebuild -project SleepSwitch.xcodeproj -scheme SleepSwitch -configuration Debug build CODE_SIGNING_ALLOWED=NO
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \\
  xcodebuild -project SleepSwitch.xcodeproj -scheme SleepSwitchCompanion -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

After changing `project.yml`, regenerate the project with `xcodegen generate`.

## Operator demo recipe

1. Open Operator from Sleep Switch and start a Codex task.
2. Confirm the Overview and Sessions surfaces show a fresh session state and only supported metrics.
3. Browse skills, apply a local tag/favourite, then inspect the original source to confirm it remains untouched.
4. On a paired iPhone, verify the compact summary describes current/stale/offline state honestly and does not expose task content.

## Current implementation status

The local data layer, native macOS Operator window, and grouped iPhone summary are implemented. The macOS status menu opens Operator. Its Skills surface filters by text/source/tag/favourite and performs copy, reveal, export, or share only on explicit user action. The app publishes only harness-level session counts, token/duration deltas, static availability codes, and queued finish-action identifiers—not raw sessions, skills, paths, prompts, or events.
