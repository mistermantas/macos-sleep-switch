# Sleep Switch

Keep long-running work awake without changing macOS sleep settings.

[Download Sleep Switch](https://github.com/mistermantas/macos-sleep-switch/releases/latest/download/Sleep-Switch.zip)

Sleep Switch holds a temporary macOS power assertion while it is active. It automatically stays awake while a supported coding agent is running, then returns sleep control to macOS when the agent exits. It is free and open source.

## Install

1. Download and unzip `Sleep-Switch.zip`.
2. Move **Sleep Switch.app** to `/Applications`.
3. Right-click the app and choose **Open** the first time.
4. Look for the coffee cup in the menu bar.

Sleep Switch starts at login by default. Uncheck **Launch at Login** in its menu whenever you want to disable that.

## Use

- Click the menu-bar icon to open the controls.
- **Keep Awake for Agents** is on by default. A filled terminal means an agent is keeping the Mac awake.
- **Sleep Display** turns off the display without sleeping or logging out of the Mac.
- **Sleep Until Agents Finish** turns off the display and wakes it once every detected agent session has ended. This is a one-shot action and is never enabled by default.
- **Keep Awake Manually** starts or stops an independent Caffeine-style session. Use **Manual Duration** for a preset or custom time.

Agent sessions allow the display to sleep. Manual sessions can optionally keep it lit. Settings cover manual display behavior, activation on launch, the default manual duration, and launch at login.

Sleep Switch prevents automatic idle sleep. Closing a MacBook lid still follows macOS clamshell behavior.

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

Sleep Switch uses Apple’s native power-management assertions:

- `PreventUserIdleSystemSleep` keeps macOS from automatically sleeping.
- `PreventUserIdleDisplaySleep` optionally keeps the display awake.

The assertions belong to the app process and are released when the manual or agent session ends, automatic agent awake is paused, or the app quits. Sleep Switch never runs `sudo`, never changes `pmset`, and does not need administrator approval.

When you choose a display action, Sleep Switch calls macOS’s built-in `pmset displaysleepnow`. This turns off only the display and does not alter any power setting. A queued agent-completion wake uses Apple’s `IOPMAssertionDeclareUserActivity` API.

There are no analytics, network requests, privileged background services, or bundled dependencies.

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
