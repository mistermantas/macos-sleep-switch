import AppKit
import SwiftUI

struct SleepSwitchPreferencesSnapshot: Equatable {
    var keepDisplayAwake: Bool
    var activateOnLaunch: Bool
    var defaultDurationSeconds: Int
    var automaticAgentAwake: Bool
    var launchAtLoginTitle: String
    var historyEnabled: Bool
    var companionStatus: String
    var isDirectBuild: Bool
    var lidClosedMinimumBatteryPercent: Int
    var lidClosedRequiresExternalPower: Bool
    var lidClosedSafetyMessage: String?
    var lidClosedDiagnostics: String
    var agentTriggers: AgentTriggerConfiguration
    var diagnosticsEnabled: Bool
    var codexActiveWindowSeconds: Int
    var coolingDescription: String?
    var aggressiveComfortTargetCelsius: Double?
    var aggressiveLaunchBoostDemand: Double?
    var statusBarAppearance: StatusBarAppearance
    var showsDockIcon: Bool
    var remoteWorkSharingEnabled: Bool
    var remoteWorkTitlesEnabled: Bool
    var remoteWorkProjectNamesEnabled: Bool

    static let empty = SleepSwitchPreferencesSnapshot(
        keepDisplayAwake: true, activateOnLaunch: false, defaultDurationSeconds: 0,
        automaticAgentAwake: true, launchAtLoginTitle: "Enable Launch at Login",
        historyEnabled: true, companionStatus: "Unavailable", isDirectBuild: false,
        lidClosedMinimumBatteryPercent: 11, lidClosedRequiresExternalPower: true,
        lidClosedSafetyMessage: nil,
        lidClosedDiagnostics: "Lid-closed diagnostics are unavailable.",
        agentTriggers: .disabled,
        diagnosticsEnabled: false, codexActiveWindowSeconds: 180, coolingDescription: nil,
        aggressiveComfortTargetCelsius: nil, aggressiveLaunchBoostDemand: nil,
        statusBarAppearance: StatusBarAppearance(iconStyle: .adaptive, showsColoredStatusDots: true),
        showsDockIcon: false,
        remoteWorkSharingEnabled: false,
        remoteWorkTitlesEnabled: false,
        remoteWorkProjectNamesEnabled: false
    )
}

enum SleepSwitchPreferencesMutation {
    case keepDisplayAwake(Bool)
    case activateOnLaunch(Bool)
    case defaultDuration(Int)
    case automaticAgentAwake(Bool)
    case historyEnabled(Bool)
    case launchAtLogin
    case lidClosedMinimumBatteryPercent(Int)
    case lidClosedRequiresExternalPower(Bool)
    case agentTriggers(AgentTriggerConfiguration)
    case diagnosticsEnabled(Bool)
    case codexActiveWindowSeconds(Int)
    case aggressiveComfortTarget(Double)
    case aggressiveLaunchBoost(Double)
    case statusBarIconStyle(StatusBarIconStyle)
    case statusBarIconScale(StatusBarIconScale)
    case showsColoredStatusDots(Bool)
    case statusBarDotEmphasis(StatusBarDotEmphasis)
    case showsDockIcon(Bool)
    case remoteWorkSharingEnabled(Bool)
    case remoteWorkTitlesEnabled(Bool)
    case remoteWorkProjectNamesEnabled(Bool)
}

@MainActor
final class SleepSwitchPreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel

    init(
        snapshotProvider: @escaping () -> SleepSwitchPreferencesSnapshot,
        apply: @escaping (SleepSwitchPreferencesMutation) -> Void,
        showDiagnostics: @escaping () -> Void,
        showCoolingDetails: @escaping () -> Void,
        showDeviceManager: @escaping () -> Void
    ) {
        viewModel = PreferencesViewModel(
            snapshotProvider: snapshotProvider,
            apply: apply,
            showDiagnostics: showDiagnostics,
            showCoolingDetails: showCoolingDetails,
            showDeviceManager: showDeviceManager
        )
        let host = NSHostingController(rootView: PreferencesWindowView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings · Sleep Switch"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 630))
        window.minSize = NSSize(width: 560, height: 530)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        viewModel.reload()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class PreferencesViewModel: ObservableObject {
    @Published private(set) var snapshot: SleepSwitchPreferencesSnapshot
    private let snapshotProvider: () -> SleepSwitchPreferencesSnapshot
    private let applyAction: (SleepSwitchPreferencesMutation) -> Void
    private let showDiagnosticsAction: () -> Void
    private let showCoolingDetailsAction: () -> Void
    private let showDeviceManagerAction: () -> Void

    init(
        snapshotProvider: @escaping () -> SleepSwitchPreferencesSnapshot,
        apply: @escaping (SleepSwitchPreferencesMutation) -> Void,
        showDiagnostics: @escaping () -> Void,
        showCoolingDetails: @escaping () -> Void,
        showDeviceManager: @escaping () -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        applyAction = apply
        showDiagnosticsAction = showDiagnostics
        showCoolingDetailsAction = showCoolingDetails
        showDeviceManagerAction = showDeviceManager
        snapshot = snapshotProvider()
    }

    func reload() { snapshot = snapshotProvider() }

    func apply(_ mutation: SleepSwitchPreferencesMutation) {
        applyAction(mutation)
        reload()
    }

    func showDiagnostics() { showDiagnosticsAction() }
    func showCoolingDetails() { showCoolingDetailsAction() }
    func showDeviceManager() { showDeviceManagerAction() }

    func copyLidClosedDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            snapshot.lidClosedDiagnostics,
            forType: .string
        )
    }
}

private struct PreferencesWindowView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            automationTab
                .tabItem { Label("Automation", systemImage: "terminal") }
            safetyTab
                .tabItem { Label("Safety", systemImage: "shield.checkered") }
            dataTab
                .tabItem { Label("Data & iPhone", systemImage: "iphone") }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 530)
    }

    private var appearanceTab: some View {
        Form {
            Section("Menu bar") {
                ForEach(StatusBarIconStyle.galleryGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 8),
                                count: 6
                            ),
                            spacing: 8
                        ) {
                            ForEach(group.styles, id: \.self) { style in
                                iconChoice(style)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                Picker("Icon scale", selection: binding(
                    get: { viewModel.snapshot.statusBarAppearance.iconScale },
                    set: { .statusBarIconScale($0) }
                )) {
                    ForEach(StatusBarIconScale.allCases, id: \.self) { scale in
                        Text(scale.title).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Status dots") {
                Toggle("Show colored status dots", isOn: binding(
                    get: { viewModel.snapshot.statusBarAppearance.showsColoredStatusDots },
                    set: { .showsColoredStatusDots($0) }
                ))
                Picker("Dot emphasis", selection: binding(
                    get: { viewModel.snapshot.statusBarAppearance.dotEmphasis },
                    set: { .statusBarDotEmphasis($0) }
                )) {
                    ForEach(StatusBarDotEmphasis.allCases, id: \.self) { emphasis in
                        Text(emphasis.title).tag(emphasis)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.snapshot.statusBarAppearance.showsColoredStatusDots)

                HStack(spacing: 14) {
                    statusDotPreview("Timed", color: .red)
                    statusDotPreview("Agents", color: .blue)
                    statusDotPreview("Manual", color: .yellow)
                }
            }

            Section("Dock") {
                Toggle("Show Sleep Switch in the Dock", isOn: binding(
                    get: { viewModel.snapshot.showsDockIcon },
                    set: { .showsDockIcon($0) }
                ))
                Text("When off, Sleep Switch stays a menu-bar app, including while Operator and Settings are open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func iconChoice(_ style: StatusBarIconStyle) -> some View {
        let isSelected = viewModel.snapshot.statusBarAppearance.iconStyle == style
        return Button {
            viewModel.apply(.statusBarIconStyle(style))
        } label: {
            VStack(spacing: 5) {
                Image(systemName: style.previewSymbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(style.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.75) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(style.title) menu bar icon")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func statusDotPreview(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
        }
    }

    private var generalTab: some View {
        Form {
            Section("Manual sessions") {
                Toggle("Keep the display awake during manual sessions", isOn: binding(
                    get: { viewModel.snapshot.keepDisplayAwake },
                    set: { .keepDisplayAwake($0) }
                ))
                Picker("Default duration", selection: binding(
                    get: { viewModel.snapshot.defaultDurationSeconds },
                    set: { .defaultDuration($0) }
                )) {
                    Text("Indefinitely").tag(0)
                    ForEach(AwakeTimeText.presetSeconds, id: \.self) { seconds in
                        Text(AwakeTimeText.duration(seconds: seconds)).tag(seconds)
                    }
                }
                Toggle("Start the default session when Sleep Switch opens", isOn: binding(
                    get: { viewModel.snapshot.activateOnLaunch },
                    set: { .activateOnLaunch($0) }
                ))
            }

            Section("Startup") {
                Button(viewModel.snapshot.launchAtLoginTitle, action: {
                    viewModel.apply(.launchAtLogin)
                })
                Text("Sleep Switch runs as a menu-bar app after you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var automationTab: some View {
        Form {
            Section("Agent automation") {
                Toggle("Keep the Mac awake while supported agents run", isOn: binding(
                    get: { viewModel.snapshot.automaticAgentAwake },
                    set: { .automaticAgentAwake($0) }
                ))
                Text("Sleep Switch releases its power assertion after the last detected session ends. Manual sessions stay independent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom local triggers") {
                Toggle("Run custom commands on agent transitions", isOn: triggerEnabledBinding)
                TextField("When agents start", text: triggerCommandBinding(\.whenAgentsStartCommand))
                TextField("When agents finish", text: triggerCommandBinding(\.whenAgentsFinishCommand))
                Text("Commands run locally through zsh only when the detected session count changes between zero and non-zero. They receive event, agent-name, and session-count environment variables; no prompts or paths are passed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Detection") {
                Toggle("Keep local agent detection diagnostics", isOn: binding(
                    get: { viewModel.snapshot.diagnosticsEnabled },
                    set: { .diagnosticsEnabled($0) }
                ))
                Picker("Codex quiet-window", selection: binding(
                    get: { viewModel.snapshot.codexActiveWindowSeconds },
                    set: { .codexActiveWindowSeconds($0) }
                )) {
                    Text("1 minute").tag(60)
                    Text("3 minutes (default)").tag(180)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                }
                Text("A Codex task without a local session-log update for this long is treated as idle. Shorter windows clear stale tasks sooner; longer windows tolerate quiet network waits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Detection Diagnostics…") { viewModel.showDiagnostics() }
                    Spacer()
                    Text("Current local state only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var safetyTab: some View {
        Form {
            if viewModel.snapshot.isDirectBuild {
                Section("Lid-closed protection") {
                    Stepper(
                        "Stop lid-closed mode at or below \(viewModel.snapshot.lidClosedMinimumBatteryPercent)% battery",
                        value: binding(
                            get: { viewModel.snapshot.lidClosedMinimumBatteryPercent },
                            set: { .lidClosedMinimumBatteryPercent($0) }
                        ),
                        in: 1...50
                    )
                    Toggle("Only allow lid-closed mode on external power", isOn: binding(
                        get: { viewModel.snapshot.lidClosedRequiresExternalPower },
                        set: { .lidClosedRequiresExternalPower($0) }
                    ))
                    if let message = viewModel.snapshot.lidClosedSafetyMessage {
                        Label(message, systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Lid-closed mode is currently allowed", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    }
                    Text("When this protection applies, Sleep Switch immediately restores normal lid behavior and keeps only standard idle-sleep prevention if a session is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("Lid-closed diagnostics")
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.snapshot.lidClosedDiagnostics)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(8)
                    Button("Copy Lid-Closed Diagnostics") {
                        viewModel.copyLidClosedDiagnostics()
                    }
                }

                Section("Cooling") {
                    Text(viewModel.snapshot.coolingDescription ?? "Cooling is unavailable in this build.")
                    if let target = viewModel.snapshot.aggressiveComfortTargetCelsius,
                       let launchBoost = viewModel.snapshot.aggressiveLaunchBoostDemand {
                        Stepper(
                            "Comfort target \(Int(target.rounded()))°C",
                            value: binding(
                                get: { target },
                                set: { .aggressiveComfortTarget($0) }
                            ),
                            in: 45...65,
                            step: 1
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Launch boost")
                                Spacer()
                                Text("\(Int((launchBoost * 100).rounded()))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: binding(
                                    get: { launchBoost },
                                    set: { .aggressiveLaunchBoost($0) }
                                ),
                                in: 0.70...1,
                                step: 0.05
                            )
                        }
                    }
                    Text("Aggressive gives every qualified fan a brief launch boost, then follows the hottest live temperature every three seconds with a cubic comfort curve. At the comfort target it eases down; 15°C above it it reaches full demand again. A rise in temperature always raises demand immediately. Maximum asks every qualified fan for full demand. Sleep Switch restores macOS fan control when cooling ends, temperature feedback is unreliable, macOS reports critical thermal pressure, or a verified maximum profile stays at or above 80°C for 30 seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Cooling Details…") { viewModel.showCoolingDetails() }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Direct-build safety controls", systemImage: "lock.shield")
                        .font(.headline)
                    Text("The App Store build uses standard macOS sleep prevention and cannot change lid behavior or fan control.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var dataTab: some View {
        Form {
            Section("Local history") {
                Toggle("Save energy and agent history on this Mac", isOn: binding(
                    get: { viewModel.snapshot.historyEnabled },
                    set: { .historyEnabled($0) }
                ))
                Text("History stays on this Mac. The iPhone companion receives only bounded, coarse summaries through your private iCloud database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("iPhone companion") {
                LabeledContent("Connection", value: viewModel.snapshot.companionStatus)
                Button("Manage Macs…") { viewModel.showDeviceManager() }
                Text("The iPhone must use the same Apple Account with iCloud enabled. A Mac must be awake, online, and running Sleep Switch to receive remote actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Remote Work") {
                Toggle("Share operational agent state", isOn: binding(
                    get: { viewModel.snapshot.remoteWorkSharingEnabled },
                    set: { .remoteWorkSharingEnabled($0) }
                ))
                Toggle("Include Codex chat titles", isOn: binding(
                    get: { viewModel.snapshot.remoteWorkTitlesEnabled },
                    set: { .remoteWorkTitlesEnabled($0) }
                ))
                .disabled(!viewModel.snapshot.remoteWorkSharingEnabled)
                Toggle("Include Codex project labels", isOn: binding(
                    get: { viewModel.snapshot.remoteWorkProjectNamesEnabled },
                    set: { .remoteWorkProjectNamesEnabled($0) }
                ))
                .disabled(!viewModel.snapshot.remoteWorkSharingEnabled)
                Text("State, timing, and harness names go through your private iCloud database. Titles and project labels are separate choices. Prompts, message text, paths, commands, files, and logs stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var triggerEnabledBinding: Binding<Bool> {
        binding(
            get: { viewModel.snapshot.agentTriggers.isEnabled },
            set: { enabled in
                var config = viewModel.snapshot.agentTriggers
                config.isEnabled = enabled
                return .agentTriggers(config)
            }
        )
    }

    private func triggerCommandBinding(
        _ keyPath: WritableKeyPath<AgentTriggerConfiguration, String>
    ) -> Binding<String> {
        binding(
            get: { viewModel.snapshot.agentTriggers[keyPath: keyPath] },
            set: { command in
                var config = viewModel.snapshot.agentTriggers
                config[keyPath: keyPath] = command
                return .agentTriggers(config)
            }
        )
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value) -> SleepSwitchPreferencesMutation
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { viewModel.apply(set($0)) }
        )
    }
}
