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
| **Support & Creator** | Opens the Uncascade website and YouTube channel, this repository, or GitHub Sponsors. |
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

## How it works

In its default Prevent Sleep mode, Sleep Switch uses Apple’s native power-management assertions:

- `PreventUserIdleSystemSleep` keeps macOS from automatically sleeping.
- `PreventUserIdleDisplaySleep` optionally keeps the display awake.

The assertions belong to the app process and are released when the manual or agent session ends, automatic agent awake is paused, or the app quits.

The optional **Prevent Sleep Even With Lid Closed** mode in the GitHub download temporarily runs `pmset disablesleep 1` after standard macOS administrator approval. A short-lived privileged watcher restores `pmset disablesleep 0` when the awake session ends or the app exits—even after a crash. Sleep Switch does not install a privileged helper or retain administrator credentials.

When you choose a display action, Sleep Switch calls macOS’s built-in `pmset displaysleepnow`. This turns off only the display and does not alter any power setting. A queued agent-completion wake uses Apple’s `IOPMAssertionDeclareUserActivity` API.

There are no analytics, network requests, installed privileged services, or bundled dependencies.

## Mac App Store

The repository includes a sandboxed Mac App Store target. Apple’s sandbox allows the native keep-awake and display-wake APIs, but blocks the global process scan and `pmset displaysleepnow` used by the full download. The store build therefore supports manual sleep-prevention sessions, opt-in Codex tracking through a user-selected folder, and wake-on-completion. The GitHub download keeps all supported agents and display controls.

See [APP_STORE.md](APP_STORE.md) for the Xcode target, submission metadata, and account handoff.

## Support & creator

- [Uncascade](https://www.uncascade.com/)
- [Uncascade on YouTube](https://www.youtube.com/@uncascade)
- [Sleep Switch on GitHub](https://github.com/mistermantas/macos-sleep-switch)
- [Sponsor on GitHub](https://github.com/sponsors/mistermantas)

## A note on heat

Keeping a Mac active uses power and can create heat during builds or other heavy work. Keep it on a hard, ventilated surface. Do not leave an active MacBook in a bag or under bedding.

## Requirements

- macOS 13 Ventura or newer
- Apple silicon or Intel Mac

The downloadable build is ad-hoc signed because this project is not distributed through the App Store. macOS may ask you to confirm the first launch with **Right-click → Open**.

## Build from source

Xcode command-line tools are required.

```sh
./build.sh
```

The universal app is written to `build/Sleep Switch.app`. To create the release archive:

```sh
./package.sh
```

Run the test suite with:

```sh
./test.sh
```

## License

[MIT](LICENSE)
