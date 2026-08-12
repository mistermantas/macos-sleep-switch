# Sleep Switch Companion — iOS release setup

The repository now contains a real SwiftUI target, `SleepSwitchCompanion`, rather than a placeholder screen. It is version `2.2.0 (16)`, targets iOS/iPadOS 17, and uses bundle identifier `lt.mantas.sleepswitch.companion`.

## CloudKit setup required once

The Mac and iOS targets share the private container `iCloud.lt.mantas.sleepswitch`.

In CloudKit Dashboard, create or select that container and add these record types to the **private database**:

| Record type | Fields |
| --- | --- |
| `MacStatus` | `payload` (Bytes), `deviceID` (String), `lastSeen` (Date), `expiresAt` (Date) |
| `InsightsHistory` | `payload` (Bytes), `deviceID` (String), `updatedAt` (Date), `expiresAt` (Date) |
| `RemoteCommand` | `targetDeviceID` (String), `action` (String), `state` (String), `createdAt` (Date), `expiresAt` (Date), `payload` (Bytes), `processedAt` (Date, optional), `accepted` (Int, optional), `resultMessage` (String, optional) |

Create query indexes for `MacStatus.deviceID`, `MacStatus.expiresAt`, `InsightsHistory.deviceID`, `InsightsHistory.expiresAt`, `RemoteCommand.targetDeviceID`, and `RemoteCommand.state`. Deploy the development schema before archiving. The app only uses the private database; there is no public record exposure.

`InsightsHistory` is intentionally bounded: it contains at most the last 24 hours of five-minute energy buckets plus 30 daily kWh summaries and coarse agent-hours summaries. It never contains prompts, output, process names, file names, or one-minute readings. When **Save Energy & Agent History** is off on the Mac, the published payload is empty and the companion shows that history is unavailable.

The Xcode project already references the container and includes iCloud entitlements for both targets. Before a production archive, set the Release entitlement environment to `Production` after the development schema is deployed and confirm that the container is assigned to both bundle IDs in Certificates, Identifiers & Profiles.

## Build and archive

```sh
xcodegen generate --spec project.yml
xcodebuild -project SleepSwitch.xcodeproj \
  -scheme SleepSwitchCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/SleepSwitchCompanion-2.2.0-16.xcarchive \
  -allowProvisioningUpdates archive
```

The connected Apple Developer account must provide an iOS App ID for `lt.mantas.sleepswitch.companion` with iCloud/CloudKit enabled. The App Store Connect app record is still a manual step: create **Sleep Switch Companion**, choose Free, attach the iOS archive, and add the privacy policy URL:

`https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md`

Suggested App Store Connect metadata:

- **Subtitle:** Check and control your Mac
- **Primary category:** Utilities
- **Secondary category:** Developer Tools
- **Price:** Free (`$0.00`)
- **Marketing URL:** `https://github.com/mistermantas/macos-sleep-switch`
- **Support URL:** `https://uncascade.com/contact/`
- **Copyright:** 2026 Mantas Vilčinskas

Suggested review note: “Sleep Switch Companion reads the signed-in user's private CloudKit database. Launch Sleep Switch on a Mac signed into the same iCloud account, leave it running and awake, then open the companion. The dashboard shows live status, bounded energy/agent history, and only the named actions advertised by that Mac build. Sleep, lock, restart, and shutdown require confirmation. There is no account registration, subscription, payment, or developer-operated server.”

## Review notes and limitations

- The Mac needs to be awake, running Sleep Switch, signed into the same iCloud account, and online for status and commands.
- Commands are named, capability-gated, addressed to one device, and expire after 90 seconds.
- Sleep, lock, restart, and shutdown require an explicit confirmation in the iOS UI.
- `Wake Display` uses the public IOKit user-activity API when the Mac is awake.
- A fully sleeping Mac cannot poll CloudKit. The companion therefore does not claim to wake a sleeping Mac; the UI leaves `Wake Mac` unavailable instead of implying that it can work.
- The sandboxed Mac App Store build supports IOKit sleep, wake-display, and keep-awake actions. Shell-backed display sleep, lock, restart, and shutdown remain direct-download capabilities until Apple approves an appropriate privileged design.
