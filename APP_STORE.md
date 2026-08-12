# Mac App Store release

Sleep Switch includes a sandboxed Xcode target for the Mac App Store. The generated Xcode project is committed so it opens directly. Build the unsigned release target with:

```sh
xcodebuild \
  -project SleepSwitch.xcodeproj \
  -scheme SleepSwitch \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

After changing `project.yml`, regenerate the project with `xcodegen generate`.

For a signed upload, archive outside a cloud-synced directory and export with
`AppStore/ExportOptions.plist`:

```sh
xcodebuild \
  -project SleepSwitch.xcodeproj \
  -scheme SleepSwitch \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/SleepSwitch.xcarchive \
  -derivedDataPath /tmp/SleepSwitch-DerivedData \
  DEVELOPMENT_TEAM=C43F5MKJF2 \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath /tmp/SleepSwitch.xcarchive \
  -exportOptionsPlist AppStore/ExportOptions.plist \
  -exportPath /tmp/SleepSwitch-Export \
  -allowProvisioningUpdates
```

## Distribution differences

| Capability | GitHub download | Mac App Store |
| --- | --- | --- |
| Manual sleep-prevention sessions | Yes | Yes |
| Keep running with the lid closed | Yes, with administrator approval | No |
| Keep the display awake manually | Yes | Yes |
| Automatic Codex tracking | Yes | Yes, after choosing `.codex` |
| Other supported agent harnesses | Yes | No |
| Put the display to sleep | Yes | No |
| Wake the display after tasks finish | Yes | Yes |
| Launch at login | On by default; can be disabled | Opt-in |

The Mac App Store requires App Sandbox. A sandboxed app can use Apple’s public power assertion APIs, but it cannot execute `/bin/ps` or `/usr/bin/pmset`. The store target therefore removes global command-line process inspection and forced display sleep. It uses a read-only, security-scoped bookmark for Codex task files and never weakens the full direct-download build.

## App Store Connect record

- **Apple ID:** `6794709246`
- **Name:** Sleep Switch for AI Agents
- **Subtitle:** Keep long-running work awake
- **Primary category:** Developer Tools
- **Secondary category:** Utilities
- **Price:** Free (`$0.00`)
- **Bundle ID:** `lt.mantas.sleepswitch`
- **SKU:** `sleep-switch-macos`
- **Support URL:** `https://uncascade.com/contact/`
- **Marketing URL:** `https://github.com/mistermantas/macos-sleep-switch`
- **Privacy policy URL:** `https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md`
- **Copyright:** 2026 Mantas Vilčinskas
- **App privacy:** Data Not Collected
- **Encryption:** No non-exempt encryption
- **Suggested age rating:** 4+

### Description

Sleep Switch keeps a Mac awake while work runs, without changing system sleep settings.

Start a manual session indefinitely or choose a duration. The display can still sleep, or stay awake when you need it. Connect your Codex folder to keep the Mac awake automatically during active Codex tasks and optionally wake the display when they finish.

Sleep Switch lives entirely in the menu bar. It has no app accounts, analytics, ads, tracking, or developer-operated network service.

Version 2.2 adds **Insights** plus the optional `Sleep Switch Companion` iOS app. Insights is a local view of estimated energy use and coarse agent activity intervals. History is saved on the Mac by default, can be paused, and can be deleted at any time. The charts never include prompts, output, file names, command lines, or session paths. The companion uses the user's private iCloud database for coarse Mac status and short-lived, named remote actions; it has no developer-operated server.

Free and open source.

### Keywords

`awake,sleep,prevent sleep,codex,developer,menu bar,productivity,agent,timer`

### Review notes

Sleep Switch is a menu-bar-only utility. Launch the app and use the coffee-cup icon in the macOS menu bar.

Manual keep-awake sessions work immediately. To test Codex tracking, choose **Connect Codex…** and select a `.codex` folder containing a `sessions` directory. Sleep Switch reads recent Codex JSONL task markers locally and read-only. No information leaves the Mac.

The app uses `IOPMAssertionCreateWithName` to prevent idle system or display sleep and `IOPMAssertionDeclareUserActivity` for the optional one-shot display wake.

For version 2.2.0 (build 16), reviewers can also open **Insights…** from the menu. The Energy tab shows the live estimate and five-minute local buckets; the Agent activity tab shows coarse intervals for supported local Codex tasks. If the test Mac has not been running long enough to produce a bucket, the app displays an empty state rather than fabricated data. **Settings → Save Energy & Agent History** pauses disk writes, and **Delete History…** removes the local SQLite rows.

The repository also contains the companion target `SleepSwitchCompanion` (bundle ID `lt.mantas.sleepswitch.companion`, iOS/iPadOS 17, version 2.2.0 build 16). It uses the private CloudKit container `iCloud.lt.mantas.sleepswitch`. When the Mac is awake and Sleep Switch is running, the companion can show status and request capability-gated actions such as Sleep Mac, Sleep Display, Wake Display, Keep Awake for Agents, and Wake Display When Agents Finish. Sleep, lock, restart, and shutdown have explicit confirmation in the iOS UI. A fully sleeping Mac cannot poll CloudKit, so Wake Mac is intentionally unavailable. CloudKit schema and App Store Connect setup are documented in `COMPANION_APP_STORE.md`.

The companion's History view is intentionally bounded: it shows daily kWh and agent-hours for up to 30 days, plus up to 24 hours of five-minute energy buckets. It does not receive prompts, output, file names, process names, or raw command lines.

The **Support & Creator** menu in this App Store build contains no donation or sponsorship action. It links to the public bug/feedback form and Uncascade contact support. The Mac app has no app accounts, subscriptions, payments, or in-app purchases; the optional companion uses the user's existing private iCloud account.

## Assets

The three 1440 × 900 screenshots uploaded to App Store Connect are:

1. `AppStore/Screenshots/Final/01-codex-automatic-awake.png`
2. `AppStore/Screenshots/Final/02-manual-awake-timer.png`
3. `AppStore/Screenshots/Final/03-support-and-creator.png`

`AppStore/Screenshots/studio.html` is the deterministic source used to render
them. `AppStore/Screenshots/Source/current-menu.png` is the real menu reference.

## Submission status

- Version 1.8.0 (build 11) was uploaded to App Store Connect on August 1, 2026,
  and accepted for processing as a universal sandboxed app.
- The v2.2.0 Mac candidate is build 16. It adds the review fixes, local Insights,
  bounded history, and the private CloudKit bridge used by the companion target.
- Screenshots, listing copy, URLs, review notes, categories, and the free price
  are configured.
- The privacy policy URL and **Data Not Collected** disclosure are published.
- App Store Connect is ready for **Update Review** after the requested physical-
  device screen recording is attached to the reviewer reply.

For a 2.2 submission, record the sandboxed TestFlight build, show **Support &
Creator → Version 2.2.0 (16)**, open **Insights…**, demonstrate the history
toggle/delete flow, then attach the recording in the review conversation and
choose **Submit for Review** to resubmit.
