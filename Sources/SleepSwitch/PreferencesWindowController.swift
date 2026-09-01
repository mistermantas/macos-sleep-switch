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
    var agentTriggers: AgentTriggerConfiguration
    var diagnosticsEnabled: Bool
    var coolingDescription: String?
    var aggressiveComfortTargetCelsius: Double?
    var aggressiveLaunchBoostDemand: Double?

    static let empty = SleepSwitchPreferencesSnapshot(
        keepDisplayAwake: true, activateOnLaunch: false, defaultDurationSeconds: 0,
        automaticAgentAwake: true, launchAtLoginTitle: "Enable Launch at Login",
        historyEnabled: true, companionStatus: "Unavailable", isDirectBuild: false,
        lidClosedMinimumBatteryPercent: 11, lidClosedRequiresExternalPower: true,
        lidClosedSafetyMessage: nil, agentTriggers: .disabled,
        diagnosticsEnabled: false, coolingDescription: nil,
        aggressiveComfortTargetCelsius: nil, aggressiveLaunchBoostDemand: nil
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
    case aggressiveComfortTarget(Double)
    case aggressiveLaunchBoost(Double)
}

@MainActor
final class SleepSwitchPreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel

    init(
        snapshotProvider: @escaping () -> SleepSwitchPreferencesSnapshot,
        apply: @escaping (SleepSwitchPreferencesMutation) -> Void,
        showDiagnostics: @escaping () -> Void,
        showCoolingDetails: @escaping () -> Void
    ) {
        viewModel = PreferencesViewModel(
            snapshotProvider: snapshotProvider,
            apply: apply,
            showDiagnostics: showDiagnostics,
            showCoolingDetails: showCoolingDetails
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

    init(
        snapshotProvider: @escaping () -> SleepSwitchPreferencesSnapshot,
        apply: @escaping (SleepSwitchPreferencesMutation) -> Void,
        showDiagnostics: @escaping () -> Void,
        showCoolingDetails: @escaping () -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        applyAction = apply
        showDiagnosticsAction = showDiagnostics
        showCoolingDetailsAction = showCoolingDetails
        snapshot = snapshotProvider()
    }

    func reload() { snapshot = snapshotProvider() }

    func apply(_ mutation: SleepSwitchPreferencesMutation) {
        applyAction(mutation)
        reload()
    }

    func showDiagnostics() { showDiagnosticsAction() }
    func showCoolingDetails() { showCoolingDetailsAction() }
}

private struct PreferencesWindowView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        TabView {
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
                Text("The iPhone must use the same Apple Account with iCloud enabled. A Mac must be awake, online, and running Sleep Switch to receive remote actions.")
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
