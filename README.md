# Sleep Switch

Keep long-running work awake without changing macOS sleep settings.

[Download Sleep Switch](https://github.com/mistermantas/macos-sleep-switch/releases/latest/download/Sleep-Switch.zip)

Sleep Switch holds a temporary macOS power assertion while it is active. Turn it off or quit and normal sleep behavior returns immediately. It is free, open source, and also shows which local coding-agent sessions are running.

## Install

1. Download and unzip `Sleep-Switch.zip`.
2. Move **Sleep Switch.app** to `/Applications`.
3. Right-click the app and choose **Open** the first time.
4. Look for the coffee cup in the menu bar.

Sleep Switch starts at login by default. Uncheck **Launch at Login** in its menu whenever you want to disable that.

## Use

- Click the cup to start or stop keeping the Mac awake.
- An empty cup means sleep follows macOS settings.
- A filled cup means Sleep Switch is active indefinitely.
- A timer means a timed session is active.
- Right-click or Command-click the cup for durations, agent sessions, and settings.
- Choose **Custom…** for any duration from 1 minute to 23 hours 59 minutes.

Under **Settings**, choose whether the display should also stay awake, whether Sleep Switch activates when launched, and the duration used by a regular click. Launch at login remains optional.

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

Sleep Switch checks the local process list every five seconds. Tracking is local-only: no process information leaves your Mac.

## How it works

Sleep Switch uses Apple’s native power-management assertions:

- `PreventUserIdleSystemSleep` keeps macOS from automatically sleeping.
- `PreventUserIdleDisplaySleep` optionally keeps the display awake.

The assertions belong to the app process and are released when the session ends or the app quits. Sleep Switch never runs `sudo`, never changes `pmset`, and does not need administrator approval.

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
