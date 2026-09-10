import SwiftUI

struct CompanionLiveActivityScreen: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject private var controller = CompanionLiveActivityController.shared
    @State private var deviceID: String

    init(model: CompanionAppModel, deviceID: String?) {
        self.model = model
        _deviceID = State(initialValue: deviceID ?? "")
    }
    private var macs: [CompanionMacStatus] { CompanionMacSelection.canonicalDevices(model.macs) }
    private var mac: CompanionMacStatus? { macs.first { $0.deviceID == deviceID } }
    private var isActive: Bool { controller.activeDeviceIDs.contains(deviceID) }
    private var isBusy: Bool { controller.busyDeviceIDs.contains(deviceID) }

    var body: some View {
        Form {
            if let mac {
                Section {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let state = CompanionLiveActivityProjection.content(for: mac, preferences: controller.preferences)
                        CompanionLiveActivityView(state: state, isStale: context.date > state.staleDate)
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    HStack {
                        Text("Lock Screen preview")
                        Spacer()
                        if isActive { Text("Active").foregroundStyle(.green) }
                    }
                }
                Section {
                    if macs.count > 1 {
                        Picker("Mac", selection: $deviceID) {
                            ForEach(macs) { Text($0.displayName).tag($0.deviceID) }
                        }
                    }
                    if isActive || !mac.isStale {
                    Button(role: isActive ? .destructive : nil) {
                        Task {
                            if isActive { await controller.stopMonitoring(deviceID: deviceID) }
                            else { await controller.startMonitoring(mac) }
                        }
                    } label: {
                        HStack {
                            Label(isActive ? "Stop Live Activity" : "Start Live Activity", systemImage: isActive ? "stop.circle.fill" : "play.circle.fill")
                            Spacer()
                            if isBusy { ProgressView() }
                        }
                    }
                    .tint(isActive ? Color.red : Color.accentColor)
                    .disabled(isBusy)
                    }
                    if mac.isStale {
                        Button("Refresh Mac", systemImage: "arrow.clockwise") { model.refresh() }
                    }
                } footer: {
                    Text("Monitoring only. Updates through iCloud for up to 8 hours.")
                }
            } else {
                Section {
                    ContentUnavailableView("Choose a Mac", systemImage: "laptopcomputer", description: Text("Connect to iCloud to start monitoring."))
                    if !macs.isEmpty {
                        Picker("Mac", selection: $deviceID) {
                            Text("Choose Mac").tag("")
                            ForEach(macs) { Text($0.displayName).tag($0.deviceID) }
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                }
            }
            if let issue = controller.issue {
                Section {
                    Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    if !controller.activitiesEnabled {
                        Link("Open iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            }
            Section {
                Picker("Primary metric", selection: preference(\.primaryMetric)) {
                    ForEach(CompanionLiveMetric.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } footer: {
                Text("Shown in the compact Dynamic Island.")
            }
            Section {
                ForEach(CompanionLiveMetric.allCases) { metric in
                    if metric == controller.preferences.primaryMetric {
                        LabeledContent { Text("Primary").foregroundStyle(.secondary) }
                            label: { Label(metric.title, systemImage: metric.symbol) }
                    } else {
                        Toggle(isOn: metricBinding(metric)) { Label(metric.title, systemImage: metric.symbol) }
                            .disabled(!controller.preferences.displayedMetrics.contains(metric) && controller.preferences.displayedMetrics.count >= 4)
                    }
                }
            } header: {
                HStack {
                    Text("Visible metrics")
                    Spacer()
                    Text("\(controller.preferences.displayedMetrics.count) of 4")
                }
            } footer: {
                if let mac, mac.systemLoad == nil {
                    Text("Update Sleep Switch on your Mac to add CPU and memory readings.")
                }
            }
            Section {
                Toggle("With a manual keep-awake session", isOn: preference(\.automaticManualSessions))
                Toggle("When agents are active", isOn: preference(\.automaticAgentActivity))
            } header: { Text("Start automatically") }
            footer: { Text("Starts when you open Sleep Switch during a session.") }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: deviceID) { _, id in
            if macs.contains(where: { $0.deviceID == id }) { model.selectDashboardMac(id) }
        }
        .task {
            await model.refreshAndWait()
            if deviceID.isEmpty { deviceID = macs.first?.deviceID ?? "" }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--demo-live-checks"), let mac {
                await CompanionLiveActivityIntegrationChecks.run(mac: mac)
            }
            if ProcessInfo.processInfo.arguments.contains("--demo-live-start"), let mac {
                await controller.startMonitoring(mac)
                if ProcessInfo.processInfo.arguments.contains("--demo-live-stop") {
                    await controller.stopMonitoring(deviceID: mac.deviceID)
                }
            }
            #endif
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<CompanionLiveActivityPreferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences[keyPath: keyPath] }, set: { value in
            var updated = controller.preferences
            updated[keyPath: keyPath] = value
            updated.metrics = updated.displayedMetrics
            controller.setPreferences(updated)
        })
    }
    private func metricBinding(_ metric: CompanionLiveMetric) -> Binding<Bool> {
        Binding(get: { controller.preferences.displayedMetrics.contains(metric) }, set: { enabled in
            var updated = controller.preferences
            if enabled { updated.metrics = updated.displayedMetrics + [metric] }
            else { updated.metrics = updated.displayedMetrics.filter { $0 != metric } }
            controller.setPreferences(updated)
        })
    }
}

struct CompanionLiveActivityLink: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @ObservedObject private var controller = CompanionLiveActivityController.shared
    var body: some View {
        NavigationLink {
            CompanionLiveActivityScreen(model: model, deviceID: mac.deviceID)
        } label: {
            HStack {
                Label("Live Activity", systemImage: "waveform.path")
                Spacer()
                if controller.activeDeviceIDs.contains(mac.deviceID) {
                    Text("Active").font(.subheadline).foregroundStyle(.green)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(18).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
    }
}
