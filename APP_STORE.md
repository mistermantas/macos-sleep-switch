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
- **Name:** Sleep Switch for Mac AI Agents
- **Subtitle:** Keep long-running work awake
- **Primary category:** Developer Tools
- **Secondary category:** Utilities
- **Price:** Free (`$0.00`)
- **Bundle ID:** `lt.mantas.sleepswitch`
- **SKU:** `sleep-switch-macos`
- **Support URL:** `https://github.com/mistermantas/macos-sleep-switch/issues`
- **Marketing URL:** `https://github.com/mistermantas/macos-sleep-switch`
- **Privacy policy URL:** `https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md`
- **Copyright:** 2026 Mantas Vilčinskas
- **App privacy:** Data Not Collected
- **Encryption:** No non-exempt encryption
- **Suggested age rating:** 4+

### Description

Sleep Switch keeps a Mac awake while work runs, without changing system sleep settings.

Start a manual session indefinitely or choose a duration. The display can still sleep, or stay awake when you need it. Connect your Codex folder to keep the Mac awake automatically during active Codex tasks and optionally wake the display when they finish.

Sleep Switch lives entirely in the menu bar. It has no accounts, analytics, ads, tracking, or network service.

Version 2.0 adds **Insights**, a local view of estimated energy use and coarse agent activity intervals. History is saved on the Mac by default, can be paused, and can be deleted at any time. The charts never include prompts, output, file names, command lines, or session paths.

Free and open source.

### Keywords

`awake,sleep,prevent sleep,codex,developer,menu bar,productivity,agent,timer`

### Review notes

Sleep Switch is a menu-bar-only utility. Launch the app and use the coffee-cup icon in the macOS menu bar.

Manual keep-awake sessions work immediately. To test Codex tracking, choose **Connect Codex…** and select a `.codex` folder containing a `sessions` directory. Sleep Switch reads recent Codex JSONL task markers locally and read-only. No information leaves the Mac.

The app uses `IOPMAssertionCreateWithName` to prevent idle system or display sleep and `IOPMAssertionDeclareUserActivity` for the optional one-shot display wake.

For version 2.0.0, reviewers can also open **Insights…** from the menu. The Energy tab shows the live estimate and five-minute local buckets; the Agent activity tab shows coarse intervals for supported local Codex tasks. If the test Mac has not been running long enough to produce a bucket, the app displays an empty state rather than fabricated data. **Settings → Save Energy & Agent History** pauses disk writes, and **Delete History…** removes the local SQLite rows.

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
- The v2.0.0 Mac candidate is build 14. It adds local Insights and bounded history;
  the iOS companion source is a preview target and is not part of this Mac App
  Store submission.
- Screenshots, listing copy, URLs, review notes, categories, and the free price
  are configured.
- The privacy policy URL and **Data Not Collected** disclosure are published.
- App Store Connect is ready for **Update Review** after the requested physical-
  device screen recording is attached to the reviewer reply.

For a v2 submission, record the sandboxed TestFlight build, show **Support &
Creator → Version 2.0.0 (14)**, open **Insights…**, demonstrate the history
toggle/delete flow, attach the recording in the review conversation, then choose
**Update Review** to resubmit.
