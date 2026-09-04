# Sleep Switch runbook

## What Operator is

Operator is the read-only operations layer inside Sleep Switch. On the Mac it makes local agent sessions, skills, machine state, and existing automations observable in one place. The remote-work layer adds a deliberately narrow private bridge: compact state reaches iPhone/iPad, and explicit phone-originated context can arrive in a private Mac inbox. It is not remote desktop, a remote shell, a full IDE, or a generic file manager.

## Privacy and ownership

- Harness adapters read whitelisted local metadata only. They do not retain prompts, tool payloads, credentials, or original task logs.
- The Operator database is local. It owns skill tags, favourites, and use counts.
- A source `SKILL.md` is never changed by Operator. Copy, reveal, export, and share happen only after a user action.
- iCloud summaries are bounded and private: live counts, safe token/duration deltas, machine state, alert state, and existing finish actions. They exclude raw skills, file paths, prompts, and event details.
- **Remote Work** is separately opt-in in Mac Settings → Data & iPhone. It adds a bounded per-work-item operational projection. Local IDs are pseudonymized; titles have their own off-by-default switch. Prompts, excerpts, paths, commands, artifacts, and logs never enter this projection.
- Phone-to-Mac context is an explicit, short-lived, 25 MB maximum transfer. The Mac validates and copies it into a private `Application Support/Sleep Switch/Remote Inbox` directory; it never chooses a project or feeds an agent automatically.

## Current sources

- `Sources/SleepSwitch/CodexSessionTracker.swift` observes task activity from local Codex session logs.
- `Sources/SleepSwitch/HermesSessionTracker.swift` observes Hermes active leases.
- `Sources/SleepSwitch/AgentTracker.swift` remains responsible for awake-session detection; Operator adapters must not change that safety behavior.
- `Sources/SleepSwitch/CompanionProtocol.swift` and `CompanionMacBridge.swift` provide the existing private-CloudKit path.
- `Sources/SleepSwitch/RemoteContextInbox.swift` is the private Mac receipt store; `RemoteInboxWindowController.swift` and Operator expose received items without traversing user directories.
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
5. Enable Remote Work on the Mac and confirm iPhone shows active, waiting, stopped, and finished work as distinct states. Enable titles only if the user wants task wording visible on their other signed-in device.

## Current implementation status

The local data layer, native macOS Operator window, and grouped iPhone summary are implemented. The macOS status menu opens Operator. Its Skills surface filters by text/source/tag/favourite and performs copy, reveal, export, or share only on explicit user action. The app publishes only harness-level session counts, token/duration deltas, static availability codes, and queued finish-action identifiers—not raw sessions, skills, paths, prompts, or events.

Remote Work is the first remote-supervision increment. It is an opt-in private-CloudKit projection of current Codex/Hermes work that currently emits only evidence-backed states: `active`, `waiting`, `rate limited`, `failed`, `stopped`, `finished`, and `unknown`. The broader lifecycle vocabulary (`stalled`, `blocked`, `ready to review`) remains reserved for later slices where the Mac has direct proof. Unavailable evidence stays `unknown` instead of producing a false alarm. The companion has a compact “Agent work” card and a dedicated list; it is not a transcript viewer.

## Remote supervision foundation — 2026-09-04

Sleep Switch’s next layer stays privacy-first and App Store-safe by treating the Mac as the execution-side observer and the iPhone/iPad as a concise review-and-control surface. The existing private CloudKit bridge remains the right backbone for compact state and a deliberately small, explicit context handoff—not a remote desktop or a generic file service.

- Safe foundation now:
  - private CloudKit status and history records for bounded machine/session summaries;
- an explicit, small, 24-hour CloudKit-asset context transfer to the Mac’s private inbox;
  - an iOS/iPadOS file-picker intake path; a Share extension can reuse the same contract later;
  - Quick Look, artifact offers, push, preview access, and approvals remain planned rather than implied.

### Current context handoff

On iPhone/iPad, the capability-gated **Remote Inbox** control picks one file, validates the 25 MB limit, stages it privately, then shows sending, waiting, delivered, rejected, or pending feedback. The selected Mac validates expiry and size before retaining a copy in `Application Support/Sleep Switch/Remote Inbox`. The Mac menu and Operator both show only those completed inbox receipts and offer an explicit **Reveal** action. They never choose a repository, run a command, or contact an agent.
- Product boundary:
  - do not sync prompts, transcript text, paths, commands, logs, or raw local history by default;
  - do not market the feature as generic remote desktop, remote shell, or remote file manager;
  - do not rely on CloudKit as bulk storage or generic file transfer; the current asset path is deliberately small, explicit, and short-lived.
- Recommended phases:
  1. richer remote-work state and attention classification over the current private CloudKit bridge;
  2. file-picker/Share-extension intake on iPhone/iPad, with Mac-side receipt into a private inbox and a separate explicit placement action;
  3. artifact handoff as explicit “give me the result” transfers, with Quick Look and share/save actions on iPhone;
  4. opt-in local preview relay using Network framework + Bonjour on the same network;
  5. optional user-controlled external relay only for away-from-home preview access, documented as a separate trust boundary.

Notes from Apple’s docs:

- CloudKit private databases can sync across Apple platforms and support encrypted private-database fields, which fits compact, user-owned supervision state: <https://developer.apple.com/icloud/cloudkit/>
- CloudKit design guidance says private databases can use custom zones, which is the right place for logically grouped remote-work records: <https://developer.apple.com/icloud/cloudkit/designing/>
- Query subscriptions support change notifications in private and public databases, and database subscriptions can notify devices when records change: <https://developer.apple.com/documentation/cloudkit/ckquerysubscription> and <https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription>
- Apple’s shared-data guidance says app groups are the supported way to share files/data between an app and its extensions: <https://developer.apple.com/documentation/technologyoverviews/shared-data> and <https://developer.apple.com/documentation/xcode/configuring-app-groups>
- Apple’s Share extension guidance makes the extension context the supported way to receive links, images, videos, webpages, and other attachments from the system share sheet: <https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html>
- Quick Look is the native review surface for many common file types on iPhone/iPad: <https://developer.apple.com/documentation/quicklook/qlpreviewcontroller>
- Apple’s networking overview and Network framework docs point to Bonjour-advertised listeners for local service discovery; local-network privacy requires declared usage and Bonjour service types: <https://developer.apple.com/documentation/technologyoverviews/networking-and-communication>, <https://developer.apple.com/documentation/network/nwlistener>, <https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription>, and <https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- App Review requires accurate metadata, disclosure of non-obvious features in review notes, and screenshots that show the app in use. That means any remote-preview, file-transfer, or approval flow needs explicit reviewer notes and visible in-app affordances: <https://developer.apple.com/app-store/review/guidelines/>
- Conservative CloudKit payload limits from Apple’s web-services reference remain a useful ceiling for planning compact records: 1 MB per record excluding assets and 50 MB asset fields. Treat this as planning guidance, not a reason to turn CloudKit into artifact transport: <https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html>
