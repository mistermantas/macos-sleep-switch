# Sleep Switch

Keep long-running work awake, with or without the lid open.

[Download Sleep Switch](https://github.com/mistermantas/macos-sleep-switch/releases/latest/download/Sleep-Switch.zip)

Sleep Switch holds a temporary macOS power assertion while it is active. It automatically stays awake while a supported coding agent is running, then returns sleep control to macOS when the agent exits. It is free and open source.

## Install

1. Download and unzip `Sleep-Switch.zip`.
2. Move **Sleep Switch.app** to `/Applications`.
3. Right-click the app and choose **Open** the first time.
4. Look for the coffee cup in the menu bar.

Sleep Switch starts at login by default. Uncheck **Launch at Login** in its menu whenever you want to disable that.

## Menu guide

Click the menu-bar icon once to open Sleep Switch. A checkmark means that an option is enabled.

| Menu item | What it does |
| --- | --- |
| **Status** | Shows whether the Mac can sleep, what is keeping it awake, and how much time remains. |
| **Awake Mode** | Chooses how automatic and manual sessions prevent sleep. |
| **Prevent Sleep** | Stops idle system sleep while a session is active. Closing the lid still follows normal macOS behavior. |
| **Prevent Sleep Even With Lid Closed** | Keeps the Mac running after the lid closes. Available in the GitHub download and asks for administrator approval when it becomes active. |
| **Cooling** | Chooses macOS fan control, early aggressive cooling, or maximum cooling on a specifically qualified Mac. Cooling is available only in a signed direct build. |
| **Cooling Details…** | Shows verified helper, fan, temperature, and qualification state. Its **Copy Diagnostics** button creates an anonymized local hardware report. |
| **Keep Awake for Agents** | Automatically prevents sleep while any supported coding agent is working. It is enabled by default. |
| **Keep Awake for Codex** | The App Store version of automatic agent awake. It watches the Codex folder you choose and stays awake only during active tasks. |
| **Agent status** | Shows the detected agent and session count. In the App Store build, **Connect Codex…** or **Change Codex Folder…** selects the local folder to watch. |
| **Sleep Display** | Turns off only the screen. The Mac stays signed in and active work continues. Available in the GitHub download. |
| **Sleep Until Agents Finish** | Turns off the screen now, keeps the Mac working, then wakes the screen once all detected sessions finish. Available in the GitHub download. |
| **Wake Display When Codex Finishes** | Arms the same one-time wake in the App Store build. It does not turn off the screen for you. |
| **Start Manual Session / Stop Manual Session** | Starts or stops a keep-awake session that is independent of agent activity. |
| **Manual Duration** | Starts a manual session indefinitely, for a preset time, or for a custom time. |
| **Settings** | Opens the behavior and startup preferences described below. |
| **Refresh Agents / Refresh Codex** | Checks for session changes immediately instead of waiting for the next automatic refresh. |
| **Support & Creator** | Opens the Uncascade website and YouTube channel, a bug/feedback form, or Uncascade contact support, and shows the installed version and build. |
| **Quit Sleep Switch** | Stops Sleep Switch, releases its power assertions, and restores normal lid sleep if the lid-closed mode was active. |

### Settings

| Setting | What it does |
| --- | --- |
| **Connect Codex… / Change Codex Folder…** | Gives the App Store build read-only access to your local Codex session folder. |
| **Manual Sessions Keep Display Awake** | Keeps the screen lit during manual sessions. Agent sessions still allow the screen to turn off. |
| **Activate on Launch** | Starts a manual session whenever Sleep Switch opens, using the selected default duration. |
| **Default Duration** | Sets the duration used by **Start Manual Session** and **Activate on Launch**. |
| **Launch at Login** | Opens Sleep Switch automatically after you sign in to the Mac. |

The default **Prevent Sleep** mode stops automatic idle sleep while leaving normal lid behavior unchanged. The direct GitHub build can also keep the Mac running with its lid closed; that mode asks for administrator approval when an awake session begins.

## Supported agents

- Codex
- Claude Code
- OpenCode
- Gemini CLI
- Antigravity CLI
- GitHub Copilot CLI
- Aider
- Goose
- Cursor Agent
- Grok CLI
- Amp
- Factory Droid
- Augment Code
- Qwen Code
- Pi

Sleep Switch checks local activity every ten seconds. Most harnesses are recognized by exact process and runtime-launcher signatures. Codex uses its local `task_started` and `task_complete` markers instead, so open but idle desktop tasks do not count as running sessions. Quiet network waits remain covered without relying on CPU usage.

Tracking is local-only. No process or session information leaves your Mac, and Sleep Switch does not install hooks or edit any agent’s configuration.

## Insights

Open **Insights…** from the menu to see two small, useful views:

- **Energy** shows the live power estimate and five-minute history for the last 24 hours, 7 days, or 30 days. Source and confidence are shown beside the estimate; missing readings stay gaps instead of becoming fake zeroes.
- **Agent activity** shows coarse running intervals for supported agents, including overnight work. It never stores prompts, output, file names, command lines, or session paths.

Energy and agent history is saved locally by default so the charts survive a restart. Sampling is once per minute and storage is capped to five-minute energy buckets for 30 days plus agent transition records. Turn **Save energy and agent history** off at any time to keep only the in-memory live view, or use **Delete History…** to remove the local database.

The Mac release has no analytics, account, or network service. The repository also contains an iOS companion preview (`SleepSwitchCompanion`) and its privacy-filtered CloudKit protocol. It is deliberately not advertised as live remote control until the iCloud container, entitlements, pairing UI, and physical-device review are provisioned.

## How it works

In its default Prevent Sleep mode, Sleep Switch uses Apple’s native power-management assertions:

- `PreventUserIdleSystemSleep` keeps macOS from automatically sleeping.
- `PreventUserIdleDisplaySleep` optionally keeps the display awake.

The assertions belong to the app process and are released when the manual or agent session ends, automatic agent awake is paused, or the app quits.

The optional **Prevent Sleep Even With Lid Closed** mode in the GitHub download temporarily runs `pmset disablesleep 1` after standard macOS administrator approval. A short-lived privileged watcher restores `pmset disablesleep 0` when the awake session ends or the app exits—even after a crash. Lid mode does not install a persistent helper or retain administrator credentials.

The direct build’s optional cooling feature uses a separately signed macOS
background helper because current macOS versions restrict AppleSMC access. The
helper accepts only the matching Sleep Switch signing identity, exposes only a
typed cooling lease, and restores macOS fan control on session end, disconnect,
sleep, wake, timeout, or failed verification. Unknown and unqualified Mac models
remain monitoring-only.

Cooling also ends the Sleep Switch awake session if macOS reports critical
thermal pressure, temperature feedback is lost, or the vetted temperature
aggregate remains at or above 80 °C for 30 seconds while maximum fan demand is
verified. That conservative cutoff is a fail-safe for Sleep Switch—not an Apple
safety limit or a promise that an enclosed MacBook is safe.

Cooling diagnostics contain the Mac model, macOS version, fixed vetted sensor
keys and readings, and fan telemetry. They omit usernames, paths, serial
numbers, agent content, and lease credentials, and are copied only when you
press **Copy Diagnostics**.

When you choose a display action, Sleep Switch calls macOS’s built-in `pmset displaysleepnow`. This turns off only the display and does not alter any power setting. A queued agent-completion wake uses Apple’s `IOPMAssertionDeclareUserActivity` API.

There are no analytics or network requests in the Mac app. The Mac App Store build contains no
privileged service. The signed direct build installs the cooling helper only
after the user selects cooling and approves it in macOS settings.

## Mac App Store

The repository includes a sandboxed Mac App Store target. Apple’s sandbox allows the native keep-awake and display-wake APIs, but blocks the global process scan and `pmset displaysleepnow` used by the full download. The store build therefore supports manual sleep-prevention sessions, opt-in Codex tracking through a user-selected folder, and wake-on-completion. The GitHub download keeps all supported agents and display controls.

See [APP_STORE.md](APP_STORE.md) for the Xcode target, submission metadata, and account handoff.

## Support & creator

- [Uncascade](https://www.uncascade.com/)
- [Uncascade on YouTube](https://www.youtube.com/@uncascade)
- [Sleep Switch on GitHub](https://github.com/mistermantas/macos-sleep-switch)
- [sponsors/mistermantas](https://github.com/sponsors/mistermantas)

## A note on heat

Keeping a Mac active uses power and can create heat during builds or other heavy work. Keep it on a hard, ventilated surface. Do not leave an active MacBook in a bag or under bedding.

## Requirements

- macOS 13 Ventura or newer
- Apple silicon or Intel Mac

Lid-closed mode is available in ordinary direct builds. Cooling additionally
requires an Apple-issued certificate so macOS can authenticate the app and its
privileged helper. Local builds can use an Apple Development certificate from
the Uncascade team. Public direct-download builds use Developer ID signing and
notarization.

## Build from source

Xcode command-line tools are required.

```sh
./build.sh
```

The universal app is written to `build/Sleep Switch.app`. To create the release archive:

```sh
./package.sh
```

To test cooling locally, sign in to the Uncascade developer team in Xcode and
build with its Apple Development identity:

```sh
SLEEP_SWITCH_SIGNING_IDENTITY="Apple Development: … (C43F5MKJF2)" \
SLEEP_SWITCH_ALLOW_DEVELOPMENT_SIGNING=1 \
  ./build.sh
```

For a cooling-capable release, use the Uncascade Developer ID identity and a
`notarytool` keychain profile. The package script submits, staples, recreates
the archive with its ticket, and runs the strict direct-distribution check:

```sh
SLEEP_SWITCH_SIGNING_IDENTITY="Developer ID Application: … (C43F5MKJF2)" \
SLEEP_SWITCH_NOTARY_PROFILE="sleep-switch-notary" \
  ./package.sh
```

Before a local cooling-capable installation, run the non-mutating preflight:

```sh
SLEEP_SWITCH_INSTALL_APP="build/Sleep Switch.app" \
  ./install-local.sh --check
```

The installer accepts only a notarized Developer ID build, requires
`SleepDisabled 0`, and refuses a running app or cooling helper. It never invokes
`sudo` or launches the app. `--install` refuses an existing copy;
`--replace` preserves that copy as a timestamped backup.

Run the test suite with:

```sh
./test.sh
./test-app-store.sh
./test-direct.sh
```

To build the companion preview in the simulator:

```sh
xcodegen generate
xcodebuild -project SleepSwitch.xcodeproj \
  -scheme SleepSwitchCompanion \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath /tmp/SleepSwitch-companion-build \
  CODE_SIGNING_ALLOWED=NO build
```

## License

[MIT](LICENSE)
