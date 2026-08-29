# Sleep Switch Companion — iOS release setup

The repository contains the SwiftUI target `SleepSwitchCompanion`. It is an MB Uncascade app with display name Sleep Switch, version `2.3.7 (28)`, targets iOS/iPadOS 17, and uses bundle identifier `lt.mantas.sleepswitch.companion`.

## CloudKit setup required once

The Mac and iOS targets share the private container `iCloud.lt.mantas.sleepswitch`.

In CloudKit Dashboard, create or select that container and add these record types to the **private database**:

| Record type | Fields |
| --- | --- |
| `MacStatus` | `payload` (Bytes), `deviceID` (String), `lastSeen` (Date), `expiresAt` (Date) |
| `InsightsHistory` | `payload` (Bytes), `deviceID` (String), `updatedAt` (Date), `expiresAt` (Date) |
| `RemoteCommand` | `targetDeviceID` (String), `action` (String), `state` (String), `createdAt` (Date), `expiresAt` (Date), `payload` (Bytes), `processedAt` (Date, optional), `accepted` (Int, optional), `resultMessage` (String, optional) |

Create query indexes for `MacStatus.deviceID`, `MacStatus.expiresAt`, `InsightsHistory.deviceID`, `InsightsHistory.expiresAt`, `RemoteCommand.targetDeviceID`, and `RemoteCommand.state`. Deploy the development schema, then promote the same schema to **Production** before archiving. Release builds use the production CloudKit environment; Debug builds continue to use Development. The app only uses the private database; there is no public record exposure.

`InsightsHistory` is intentionally bounded: it contains at most the last 24 hours of five-minute energy buckets plus 30 daily kWh summaries and coarse agent-hours summaries. It never contains prompts, output, process names, file names, or one-minute readings. When **Save Energy & Agent History** is off on the Mac, the published payload is empty and the companion shows that history is unavailable.

The Xcode project already references the container and includes separate Debug and Release iCloud entitlements for both targets. Run `./verify-distribution.sh` before an archive; it fails if Release is not Production or if either target points at the wrong entitlement. Confirm that the container is assigned to both bundle IDs in Certificates, Identifiers & Profiles.

## Build and archive

```sh
xcodegen generate --spec project.yml
xcodebuild -project SleepSwitch.xcodeproj \
  -scheme SleepSwitchCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/SleepSwitchCompanion-2.3.7-28.xcarchive \
  -allowProvisioningUpdates archive
```

The connected Apple Developer account must provide an iOS App ID for `lt.mantas.sleepswitch.companion` with iCloud/CloudKit enabled. The App Store Connect record is **Sleep Switch Companion** (Apple ID `6800694858`), set to Free with worldwide availability. Build `2.3.7 (28)` automatically replaces a stale saved Mac identity with the freshest online record with the same Mac name after an app reinstall, macOS upgrade, or distribution-channel change, without silently retargeting controls to another Mac. It also includes the full dashboard, inspectable Insights charts, precise Mac-vs-phone freshness labels, visible command progress, and the Mac publisher watchdog. The Mac build checks for remote commands every three seconds without republishing history on each poll. The screenshots, metadata, review contact, Content Rights declaration, and App Privacy declaration are configured in App Store Connect. The privacy policy URL is set to:

`https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md`

Bundle IDs are fixed once an App Store Connect app record is created. This companion uses the existing `lt.mantas.sleepswitch.companion` identifier; do not create a second companion record under a different identifier.

Suggested App Store Connect metadata:

- **Name:** Sleep Switch Companion
- **Subtitle:** Remote status & controls
- **Promotional text:** Check a paired computer’s status, energy use, thermals, fans, and coding activity. Send private, capability-gated remote actions.
- **Description:**

  Sleep Switch Companion is a private remote status and control app for Sleep Switch.

  When a paired computer is awake and running Sleep Switch, see its connection state, uptime, current power estimate, temperatures, fan status, battery and charging state, and active coding sessions. Review the energy and activity history stored by Sleep Switch.

  Request only the controls that the paired computer explicitly makes available: keep-awake settings, manual sessions, display sleep, lock, sleep, restart, and shut down. Destructive actions require confirmation. Commands are capability-gated, addressed to one paired computer, and expire automatically.

  Setup is simple: install and open Sleep Switch on the paired computer, sign in to the same Apple Account on both devices with iCloud enabled, keep the computer awake and online, then open Sleep Switch Companion and tap Retry.

  All status data and commands use your private iCloud database. Sleep Switch Companion does not create accounts, require a subscription or payment, or operate a developer server. It never sends prompts, files, or terminal output.

- **Keywords:** remote,energy,thermal,fan,computer,coding,uptime
- **Primary category:** Utilities
- **Secondary category:** Developer Tools
- **Price:** Free (`$0.00`)
- **Marketing URL:** `https://github.com/mistermantas/macos-sleep-switch`
- **Support URL:** `https://uncascade.com/contact/`
- **Copyright:** 2026 MB Uncascade

## Paste-ready App Review Information

Use the following text in **App Review Information → Notes**, replacing the video placeholder with the public, unlisted video URL:

> Sleep Switch Companion works with one designated computer running the Sleep Switch desktop app. The pairing is automatic: both physical devices must be signed into the same Apple Account with iCloud enabled. The app reads only that account’s private CloudKit database. There is no account registration, no shared demo account, no subscription, and no developer-operated server.
>
> Demo video, recorded on physical hardware and showing the complete pairing and control flow: **[PASTE UNLISTED VIDEO URL HERE]**
>
> The recording begins with launching Sleep Switch on the designated computer, confirms that it is awake, online, and signed into the same Apple Account, then launches Sleep Switch Companion on a physical iPhone/iPad. It shows automatic discovery of the paired computer, live status, energy and activity history, and the confirmation/result flow for a remote action.
>
> Review setup, if you are reproducing the recording: (1) install and open Sleep Switch on the designated computer, (2) sign into the same Apple Account on both devices with iCloud enabled, (3) keep the computer awake, online, and running Sleep Switch, and (4) open the companion and tap Retry. No pairing code, local-network address, login, or sample file is required.
>
> The companion intentionally cannot discover a computer belonging to a different Apple Account. Therefore, “No paired computer” is the expected state on a review device that has no companion computer publishing to that review device’s private iCloud database. The demo video shows the designated paired hardware together as requested.
>
> Available remote actions are explicitly advertised by the designated computer and are capability-gated. Sleep, lock, restart, and shut down require confirmation. Requests are addressed to one device and expire after 90 seconds. The companion never sends arbitrary commands, prompts, files, or terminal output.

Suggested reply in the App Review conversation:

> Hello App Review,
>
> Thank you for the clarification. We updated the App Review Information with a link to a physical-device video that shows the designated computer and physical iPhone/iPad together, including the automatic private-iCloud pairing setup and the complete workflow.
>
> Sleep Switch Companion is intentionally account-private: it discovers only a computer running Sleep Switch under the same Apple Account with iCloud enabled. It has no login or shared demo account, so “No paired computer” is expected on a review device with no designated computer publishing to that device’s private iCloud database. The attached recording demonstrates the required hardware pairing and live controls.
>
> We also removed the Apple product reference from the customer-facing App Store metadata. Thank you for reviewing the updated submission.

## Review notes and limitations

- The Mac needs to be awake, running Sleep Switch, signed into the same iCloud account, and online for status and commands.
- Commands are named, capability-gated, addressed to one device, and expire after 90 seconds.
- Sleep, lock, restart, and shutdown require an explicit confirmation in the iOS UI.
- `Wake Display` uses the public IOKit user-activity API when the Mac is awake.
- A fully sleeping Mac cannot poll CloudKit. The companion therefore does not claim to wake a sleeping Mac; the UI leaves `Wake Mac` unavailable instead of implying that it can work.
- The sandboxed Mac App Store build supports IOKit sleep, wake-display, and keep-awake actions. Shell-backed display sleep, lock, restart, and shutdown remain direct-download capabilities until Apple approves an appropriate privileged design.
