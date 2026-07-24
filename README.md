# Sleep Switch

A tiny macOS menu-bar switch for one system setting: whether the Mac is allowed to sleep.

[Download Sleep Switch](https://github.com/mistermantas/macos-sleep-switch/releases/latest/download/Sleep-Switch.zip)

## Install

1. Download and unzip `Sleep-Switch.zip`.
2. Move **Sleep Switch.app** to `/Applications`.
3. Right-click the app and choose **Open** the first time.
4. Look for the moon icon in the menu bar.

Sleep Switch starts at login by default. Uncheck **Launch at Login** in its menu whenever you want to disable that.

## Use

- A moon with `zzz` means sleep is allowed.
- A filled moon means sleep prevention is on.
- Choose **Prevent sleep** or **Allow sleep** to change the setting.
- macOS asks for administrator approval before each change.

Opening, quitting, installing, or refreshing the app never changes the sleep setting. Only choosing the toggle does.

## What it runs

Sleep Switch reads the current state with:

```sh
/usr/bin/pmset -g custom
```

After an explicit menu click and administrator approval, it runs one of:

```sh
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

There are no analytics, network requests, background services, or bundled dependencies.

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

## License

[MIT](LICENSE)
