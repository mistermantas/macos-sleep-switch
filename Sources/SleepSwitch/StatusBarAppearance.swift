import AppKit

/// The primary symbol can be semantic (Adaptive) or a stable personal marker.
/// The small colored dot continues to carry live state in either case.
enum StatusBarIconStyle: String, CaseIterable, Codable, Equatable {
    case adaptive
    case moon
    case cup
    case terminal
    case bolt
    case power
    case sun
    case bed
    case timer
    case hourglass
    case clock
    case battery
    case fan
    case cpu
    case sparkles
    case wand
    case brain
    case paperplane
    case flame
    case leaf
    case tortoise
    case hare
    case shield
    case gear
    case waveform
    case star
    case heart
    case eye
    case bell
    case cloud
    case globe
    case lock
    case key
    case link
    case infinity
    case pawprint
    case walk
    case run
    case seal
    case flag
    case bookmark
    case diamond
    case hexagon
    case grid
    case sliders
    case command
    case lightbulb
    case book

    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .moon: "Moon"
        case .cup: "Caffeine"
        case .terminal: "Terminal"
        case .bolt: "Bolt"
        case .power: "Power"
        case .sun: "Sun"
        case .bed: "Bed"
        case .timer: "Timer"
        case .hourglass: "Hourglass"
        case .clock: "Clock"
        case .battery: "Battery"
        case .fan: "Fan"
        case .cpu: "CPU"
        case .sparkles: "Sparkles"
        case .wand: "Wand"
        case .brain: "Brain"
        case .paperplane: "Flight"
        case .flame: "Flame"
        case .leaf: "Leaf"
        case .tortoise: "Tortoise"
        case .hare: "Hare"
        case .shield: "Shield"
        case .gear: "Gear"
        case .waveform: "Waveform"
        case .star: "Star"
        case .heart: "Heart"
        case .eye: "Eye"
        case .bell: "Bell"
        case .cloud: "Cloud"
        case .globe: "Globe"
        case .lock: "Lock"
        case .key: "Key"
        case .link: "Link"
        case .infinity: "Infinity"
        case .pawprint: "Paw"
        case .walk: "Walk"
        case .run: "Run"
        case .seal: "Seal"
        case .flag: "Flag"
        case .bookmark: "Bookmark"
        case .diamond: "Diamond"
        case .hexagon: "Hexagon"
        case .grid: "Grid"
        case .sliders: "Sliders"
        case .command: "Command"
        case .lightbulb: "Light"
        case .book: "Book"
        }
    }

    var previewSymbolName: String {
        switch self {
        case .adaptive: "switch.2"
        case .moon: "moon.fill"
        case .cup: "cup.and.saucer.fill"
        case .terminal: "terminal.fill"
        case .bolt: "bolt.fill"
        case .power: "power"
        case .sun: "sun.max.fill"
        case .bed: "bed.double.fill"
        case .timer: "timer"
        case .hourglass: "hourglass"
        case .clock: "clock.fill"
        case .battery: "battery.100percent"
        case .fan: "fan.fill"
        case .cpu: "cpu.fill"
        case .sparkles: "sparkles"
        case .wand: "wand.and.stars"
        case .brain: "brain.head.profile"
        case .paperplane: "paperplane.fill"
        case .flame: "flame.fill"
        case .leaf: "leaf.fill"
        case .tortoise: "tortoise.fill"
        case .hare: "hare.fill"
        case .shield: "shield.fill"
        case .gear: "gearshape.fill"
        case .waveform: "waveform.path.ecg"
        case .star: "star.fill"
        case .heart: "heart.fill"
        case .eye: "eye.fill"
        case .bell: "bell.fill"
        case .cloud: "cloud.fill"
        case .globe: "globe"
        case .lock: "lock.fill"
        case .key: "key.fill"
        case .link: "link"
        case .infinity: "infinity"
        case .pawprint: "pawprint.fill"
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .seal: "checkmark.seal.fill"
        case .flag: "flag.fill"
        case .bookmark: "bookmark.fill"
        case .diamond: "diamond.fill"
        case .hexagon: "hexagon.fill"
        case .grid: "square.grid.2x2.fill"
        case .sliders: "slider.horizontal.3"
        case .command: "command"
        case .lightbulb: "lightbulb.fill"
        case .book: "book.closed.fill"
        }
    }

    func symbolName(for adaptiveSymbolName: String) -> String {
        self == .adaptive ? adaptiveSymbolName : previewSymbolName
    }

    static func persisted(from rawValue: String?) -> StatusBarIconStyle {
        StatusBarIconStyle(rawValue: rawValue ?? "") ?? .adaptive
    }

    static let galleryGroups: [StatusBarIconGroup] = [
        StatusBarIconGroup(
            id: "everyday",
            title: "Everyday",
            styles: [.adaptive, .moon, .cup, .sun, .bed, .timer, .hourglass, .clock]
        ),
        StatusBarIconGroup(
            id: "work",
            title: "Work",
            styles: [.terminal, .cpu, .sparkles, .wand, .brain, .paperplane]
        ),
        StatusBarIconGroup(
            id: "energy",
            title: "Energy",
            styles: [.bolt, .power, .battery, .fan, .flame, .waveform]
        ),
        StatusBarIconGroup(
            id: "quiet",
            title: "Quiet",
            styles: [.leaf, .tortoise, .hare, .shield, .gear]
        ),
        StatusBarIconGroup(
            id: "signals",
            title: "Signals",
            styles: [.star, .heart, .eye, .bell, .cloud, .globe, .lock, .key, .link, .infinity]
        ),
        StatusBarIconGroup(
            id: "utilities",
            title: "Utilities",
            styles: [.pawprint, .walk, .run, .seal, .flag, .bookmark, .diamond, .hexagon, .grid, .sliders, .command, .lightbulb, .book]
        )
    ]
}

struct StatusBarIconGroup: Identifiable {
    let id: String
    let title: String
    let styles: [StatusBarIconStyle]
}

enum StatusBarIconScale: String, CaseIterable, Codable, Equatable {
    case compact
    case standard
    case prominent

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .prominent: "Prominent"
        }
    }

    var symbolConfiguration: NSImage.SymbolConfiguration {
        switch self {
        case .compact:
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        case .standard:
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        case .prominent:
            NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        }
    }

    static func persisted(from rawValue: String?) -> StatusBarIconScale {
        StatusBarIconScale(rawValue: rawValue ?? "") ?? .standard
    }
}

enum StatusBarDotEmphasis: String, CaseIterable, Codable, Equatable {
    case subtle
    case standard
    case bold

    var title: String {
        switch self {
        case .subtle: "Subtle"
        case .standard: "Standard"
        case .bold: "Bold"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .subtle: 6.5
        case .standard: 8
        case .bold: 9.5
        }
    }

    var baselineOffset: CGFloat {
        switch self {
        case .subtle: 1
        case .standard: 1
        case .bold: 0.5
        }
    }

    static func persisted(from rawValue: String?) -> StatusBarDotEmphasis {
        StatusBarDotEmphasis(rawValue: rawValue ?? "") ?? .standard
    }
}

enum StatusBarDotColor: Equatable {
    case red
    case amber
    case blue
    case purple
    case orange

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .amber: .systemYellow
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .orange: .systemOrange
        }
    }

    var accessibilityName: String {
        switch self {
        case .red: "red"
        case .amber: "amber"
        case .blue: "blue"
        case .purple: "purple"
        case .orange: "orange"
        }
    }
}

enum StatusBarIndicator: Equatable {
    case idle
    case timedManualSession
    case manualSession
    case agentsRunning
    case agentCooldown
    case finishActionQueued
    case restoringLidSleep
    case unavailable

    var dotColor: StatusBarDotColor? {
        switch self {
        case .idle:
            nil
        case .timedManualSession:
            .red
        case .manualSession:
            .amber
        case .agentsRunning:
            .blue
        case .agentCooldown, .finishActionQueued:
            .purple
        case .restoringLidSleep:
            .orange
        case .unavailable:
            .red
        }
    }

    var accessibilityDescription: String {
        guard let dotColor else { return "no status dot" }
        return "\(dotColor.accessibilityName) status dot"
    }
}

struct StatusBarAppearance: Equatable {
    let iconStyle: StatusBarIconStyle
    let iconScale: StatusBarIconScale
    let showsColoredStatusDots: Bool
    let dotEmphasis: StatusBarDotEmphasis

    init(defaults: UserDefaults = .standard) {
        iconStyle = StatusBarIconStyle.persisted(
            from: defaults.string(forKey: SleepSwitchPreferenceKey.statusBarIconStyle)
        )
        iconScale = StatusBarIconScale.persisted(
            from: defaults.string(forKey: SleepSwitchPreferenceKey.statusBarIconScale)
        )
        showsColoredStatusDots = defaults.bool(
            forKey: SleepSwitchPreferenceKey.showsColoredStatusDots
        )
        dotEmphasis = StatusBarDotEmphasis.persisted(
            from: defaults.string(forKey: SleepSwitchPreferenceKey.statusBarDotEmphasis)
        )
    }

    init(
        iconStyle: StatusBarIconStyle,
        iconScale: StatusBarIconScale = .standard,
        showsColoredStatusDots: Bool,
        dotEmphasis: StatusBarDotEmphasis = .standard
    ) {
        self.iconStyle = iconStyle
        self.iconScale = iconScale
        self.showsColoredStatusDots = showsColoredStatusDots
        self.dotEmphasis = dotEmphasis
    }

    func dotTitle(for indicator: StatusBarIndicator) -> NSAttributedString {
        guard showsColoredStatusDots, let dotColor = indicator.dotColor else {
            return NSAttributedString(string: "")
        }

        return NSAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: dotColor.nsColor,
                .font: NSFont.systemFont(ofSize: dotEmphasis.pointSize, weight: .bold),
                .baselineOffset: dotEmphasis.baselineOffset
            ]
        )
    }
}
