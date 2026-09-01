# Sleep Switch release plan

## Verification checklist

- [x] Plan and release constraints recorded.
- [x] Live thermal/fan delivery is correct from Mac status publication through iOS UI.
- [ ] Agent-finish sleep and shutdown are safe, persisted, and controllable from macOS and iOS.
- [ ] Focused configurable widgets render from the shared snapshot in all supported families.
- [ ] macOS tests and iOS simulator build pass.
- [ ] New iOS archive is exported and uploaded to App Store Connect.
- [ ] New macOS archive is exported and uploaded to App Store Connect, or its credential blocker is evidenced.

## Approach

The Mac remains the source of truth. It publishes a compact `CompanionMacStatus` to private CloudKit; iOS refreshes that status, writes a reduced app-group widget snapshot, and sends expiring named commands back to the Mac. Widgets never talk directly to CloudKit and never control the Mac.

## Milestones

### 1. Thermal freshness [ ]

Scope: trace the status heartbeat, CloudKit subscription/refresh, and iOS thermal card. Ensure fan RPM and thermal timestamps update with status changes rather than only on an unrelated refresh.

Key files: `CompanionMacBridge.swift`, `CompanionCloudStore.swift`, `CompanionApp.swift`, `CompanionDashboard.swift`.

Acceptance: an RPM or temperature change reaches the iOS thermal surface during normal status publication; stale status remains clearly labelled.

Verify: protocol/unit tests, iOS simulator build, targeted source review.

### 2. Agent-finish power actions [ ]

Scope: introduce explicit sleep-after-agents and shutdown-after-agents modes, persist the selected mode on the Mac, schedule only on a genuine nonzero-to-zero transition, and expose safe iOS controls with destructive confirmation for shutdown.

Key files: `CompanionProtocol.swift`, `main.swift`, awake/session coordination, companion dashboard.

Acceptance: the selected action survives refreshes; shutdown cannot happen from a stale remote state or a false transition.

Verify: protocol tests covering command validation and agent transitions; macOS/iOS builds.

### 3. Widget family [ ]

Scope: add configurable overview, battery, thermal, agent, and focused status widgets. Provide per-widget Mac selection, title visibility, and metric-focused configurations for Home Screen and Lock Screen families.

Key files: `CompanionWidgetShared.swift`, `SleepSwitchCompanionWidgets.swift`, widget/app intents, companion snapshot publisher.

Acceptance: at least five useful widget types beyond the current overview, all sourced from the app-group snapshot and graceful when a chosen Mac is unavailable.

Verify: widget target build and generated widget configuration review.

### 4. Release [ ]

Scope: update build numbers, archive/export, upload iOS with the supplied API key, then archive/export/upload macOS if App Store distribution identities are available.

Acceptance: App Store Connect reports the new iOS build valid; Mac upload is complete or blocked only by an evidenced Apple certificate requirement.

Verify: `./test.sh`, `./test-direct.sh`, iOS simulator build, signed archive inspection, App Store Connect build query.

## Risks and mitigations

1. CloudKit pushes are not a reliable sub-second stream. Mitigation: retain periodic app refresh and make the Mac publish whenever the material status fingerprint changes; widgets show timestamped cached values.
2. Agent detection can flap. Mitigation: use the existing debounced transition model and require an actual active-to-empty transition before a queued finish action executes.
3. A shutdown is destructive. Mitigation: explicit queued state, clear macOS/iOS labels, remote confirmation, and cancellation whenever a new agent appears before execution.
4. macOS App Store export currently lacks Mac App Distribution and Mac Installer Distribution certificates. Mitigation: do not substitute a development-signed build; record the exact Apple credential blocker.

## Acceptance flow

1. Open a paired Mac in iOS and change cooling; see a fresh thermal timestamp and RPM values.
2. Add a Battery and a Thermal widget, select a Mac for each, hide the title on one, and confirm the selected values remain distinct.
3. Queue sleep-after-agents, then shutdown-after-agents; confirm shutdown requires an explicit destructive confirmation and only runs after agents finish.
4. Build, export, and verify the iOS artifact in App Store Connect.

## Decision log

- 2026-09-02: Treat widget controls as display configuration only. Remote Mac commands stay in the app so a stale widget cannot cause a power action.
- 2026-09-02: Release target is iOS build 32 or higher because builds 30 and 31 are already reserved/used in App Store Connect.
- 2026-09-02: The foreground companion now refetches private CloudKit status every 15 seconds while active, supplementing the silent-push subscription. Cooling displays the status freshness so cached values are not mistaken for live readings.
