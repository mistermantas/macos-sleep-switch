import CloudKit
import SwiftUI

@main
struct SleepSwitchCompanionApp: App {
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup {
            CompanionHomeView(model: model)
        }
    }
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var macs: [CompanionMacStatus] = []
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false

    private let cloud = CompanionCloudClient()

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        Task {
            let accountStatus = await cloud.accountStatus()
            self.accountStatus = accountStatus
            guard accountStatus == .available else {
                self.message = "Sign in to iCloud on this iPhone to see a paired Mac."
                self.macs = []
                self.isLoading = false
                return
            }
            do {
                self.macs = try await cloud.fetchMacs()
                if self.macs.isEmpty {
                    self.message = "No Mac is paired yet. Start pairing from Sleep Switch on your Mac."
                }
            } catch {
                self.message = "CloudKit is not configured for this build yet."
            }
            self.isLoading = false
        }
    }
}

struct CompanionHomeView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.macs.isEmpty {
                        ContentUnavailableView(
                            "No paired Mac",
                            systemImage: "laptopcomputer",
                            description: Text(model.message ?? "Pair Sleep Switch on your Mac to begin.")
                        )
                    } else {
                        ForEach(model.macs) { mac in
                            MacStatusRow(mac: mac)
                        }
                    }
                }

                Section("Companion") {
                    Label("Private iCloud connection", systemImage: "lock.icloud")
                    Text("This companion reads coarse status and history only. Agent prompts, commands, and file paths stay on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sleep Switch")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                    .disabled(model.isLoading)
                }
            }
            .task { model.refresh() }
        }
    }
}

private struct MacStatusRow: View {
    let mac: CompanionMacStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(mac.isStale ? .secondary : Color.accentColor)
                Text(mac.displayName)
                    .font(.headline)
                Spacer()
                Text(mac.isStale ? "Stale" : "Online")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mac.isStale ? Color.secondary : Color.green)
            }
            Text("Last seen \(mac.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label("\(mac.activeSessionCount) sessions", systemImage: "terminal")
                Label(mac.powerSource.title, systemImage: "bolt")
                if let battery = mac.batteryPercent {
                    Label("\(Int(battery.rounded()))%", systemImage: "battery.75")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}
