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

Free and open source.

### Keywords

`awake,sleep,prevent sleep,codex,developer,menu bar,productivity,agent,timer`

### Review notes

Sleep Switch is a menu-bar-only utility. Launch the app and use the coffee-cup icon in the macOS menu bar.

Manual keep-awake sessions work immediately. To test Codex tracking, choose **Connect Codex…** and select a `.codex` folder containing a `sessions` directory. Sleep Switch reads recent Codex JSONL task markers locally and read-only. No information leaves the Mac.

The app uses `IOPMAssertionCreateWithName` to prevent idle system or display sleep and `IOPMAssertionDeclareUserActivity` for the optional one-shot display wake.

## Assets

The three 1440 × 900 screenshots uploaded to App Store Connect are:

1. `AppStore/Screenshots/Final/01-codex-automatic-awake.png`
2. `AppStore/Screenshots/Final/02-manual-awake-timer.png`
3. `AppStore/Screenshots/Final/03-support-and-creator.png`

`AppStore/Screenshots/studio.html` is the deterministic source used to render
them. `AppStore/Screenshots/Source/current-menu.png` is the real menu reference.

## Submission status

- Version 1.7.0 (build 10) was uploaded to App Store Connect on July 27, 2026,
  and accepted for processing as a universal sandboxed app.
- Screenshots, listing copy, URLs, review notes, categories, and the free price
  are configured.
- The privacy policy URL and **Data Not Collected** disclosure are published.
- App Store Connect still requires the reviewer contact phone number before the
  version metadata can be saved.

After processing finishes, create or select macOS version 1.7.0, choose build
10, complete any remaining reviewer contact fields, and submit it for review.
