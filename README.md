# Sleep Switch

Keep local coding agents running when your MacBook lid is closed.

[Download Sleep Switch](https://github.com/mistermantas/macos-sleep-switch/releases/latest/download/Sleep-Switch.zip)

Sleep Switch shows the agent sessions running on your Mac, alongside the system sleep setting they depend on. It is free, open source, and stays out of the way in the menu bar.

## Install

1. Download and unzip `Sleep-Switch.zip`.
2. Move **Sleep Switch.app** to `/Applications`.
3. Right-click the app and choose **Open** the first time.
4. Look for the moon icon in the menu bar.

Sleep Switch starts at login by default. Uncheck **Launch at Login** in its menu whenever you want to disable that.

## Use

- A moon with `zzz` means sleep is allowed.
- A filled moon means sleep prevention is on.
- Open the menu to see detected local agent sessions.
- Choose **Prevent sleep** or **Allow sleep** to change the setting.
- macOS asks for administrator approval before each change.

Opening, quitting, installing, or refreshing the app never changes the sleep setting. Only choosing the toggle does.

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

## What it runs

Sleep Switch reads the current state with:

```sh
/usr/bin/pmset -g
```

After an explicit menu click and administrator approval, it runs one of:

```sh
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

There are no analytics, network requests, privileged background services, or bundled dependencies.

## A note on heat

Keeping a MacBook awake with its lid closed uses normal active power and can create heat during builds or other heavy work. Keep it on a hard, ventilated surface. Do not leave an active MacBook in a bag or under bedding.

## Requirements

- macOS 13 Ventura or newer
- Apple silicon or Intel Mac
- An administrator account to change the sleep setting

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

Run the agent detection tests with:

```sh
./test.sh
```

## License

[MIT](LICENSE)
