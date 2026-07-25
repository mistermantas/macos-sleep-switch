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

## Distribution differences

| Capability | GitHub download | Mac App Store |
| --- | --- | --- |
| Manual Caffeine-style sessions | Yes | Yes |
| Keep the display awake manually | Yes | Yes |
| Automatic Codex tracking | Yes | Yes, after choosing `.codex` |
| Other supported agent harnesses | Yes | No |
| Put the display to sleep | Yes | No |
| Wake the display after tasks finish | Yes | Yes |
| Launch at login | On by default; can be disabled | Opt-in |

The Mac App Store requires App Sandbox. A sandboxed app can use Apple’s public power assertion APIs, but it cannot execute `/bin/ps` or `/usr/bin/pmset`. The store target therefore removes global command-line process inspection and forced display sleep. It uses a read-only, security-scoped bookmark for Codex task files and never weakens the full direct-download build.

## App Store Connect draft

- **Name:** Sleep Switch
- **Subtitle:** Stay awake while work runs
- **Primary category:** Utilities
- **Price:** Free
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

`awake,caffeine,sleep,codex,developer,menu bar,productivity,agent,timer`

### Review notes

Sleep Switch is a menu-bar-only utility. Launch the app and use the coffee-cup icon in the macOS menu bar.

Manual keep-awake sessions work immediately. To test Codex tracking, choose **Connect Codex…** and select a `.codex` folder containing a `sessions` directory. Sleep Switch reads recent Codex JSONL task markers locally and read-only. No information leaves the Mac.

The app uses `IOPMAssertionCreateWithName` to prevent idle system or display sleep and `IOPMAssertionDeclareUserActivity` for the optional one-shot display wake.

## Assets

Mac submissions require one to ten screenshots. Use 1440 × 900 or another accepted 16:10 Mac size. A practical first set is:

1. Automatic Codex task awake state.
2. Manual duration controls.
3. Display behavior and About & Support links.

## Account handoff

The account holder needs to:

1. Sign the latest Apple Developer agreement.
2. Sign into Xcode and create or install an Apple Development and Apple Distribution identity.
3. register `lt.mantas.sleepswitch` and select the developer team in the Xcode target.
4. Create the macOS app record in App Store Connect using the values above.
5. Confirm the app name, seller/developer name, countries, free pricing, age rating, privacy answers, and export-compliance answers.
6. Provide the final screenshots and support/privacy URLs.
7. Choose the uploaded build, add it for review, and make the final **Submit for Review** decision.

Once signing exists locally, the archive can be built, validated, and uploaded from Xcode. App Store Connect metadata and uploads can also be automated with an App Store Connect API key granted by the account holder.
