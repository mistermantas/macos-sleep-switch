import AppKit
import SwiftUI

@MainActor
final class CompanionDeviceManagerWindowController: NSWindowController {
    private let viewModel = CompanionDeviceManagerViewModel()

    init() {
        let host = NSHostingController(rootView: CompanionDeviceManagerView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "Macs · Sleep Switch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 520))
        window.minSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.reload()
    }
}

@MainActor
private final class CompanionDeviceManagerViewModel: ObservableObject {
    @Published private(set) var macs: [CompanionMacStatus] = []
    @Published private(set) var isLoading = false
    @Published var issue: String?
    @Published var pendingRemoval: CompanionMacStatus?
    @Published var showsDuplicateConfirmation = false

    private let cloud: CompanionCloudStore

    init(cloud: CompanionCloudStore = CompanionCloudStore()) {
        self.cloud = cloud
    }

    var exactDuplicateGroups: [[CompanionMacStatus]] {
        Dictionary(grouping: macs.compactMap { mac -> CompanionMacStatus? in
            guard let fingerprint = mac.machineFingerprint, !fingerprint.isEmpty else { return nil }
            return mac
        }, by: { $0.machineFingerprint ?? "" })
        .values
        .filter { $0.count > 1 }
    }

    var legacyDuplicateGroups: [[CompanionMacStatus]] {
        Dictionary(grouping: macs.filter { $0.machineFingerprint == nil }, by: \.displayName)
            .values
            .filter { $0.count > 1 }
    }

    var hasDuplicateRecords: Bool {
        !exactDuplicateGroups.isEmpty || !legacyDuplicateGroups.isEmpty
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        issue = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                self.macs = try await self.cloud.fetchMacs()
                    .sorted { $0.lastSeen > $1.lastSeen }
                self.issue = self.cloud.consumeLastIssue()
            } catch {
                self.issue = "Couldn’t load Macs from private iCloud. \(error.localizedDescription)"
            }
        }
    }

    func remove(_ mac: CompanionMacStatus) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cloud.deleteDeviceData(for: mac.deviceID)
                self.macs.removeAll { $0.deviceID == mac.deviceID }
                self.pendingRemoval = nil
            } catch {
                self.issue = "Couldn’t remove \(mac.displayName). \(error.localizedDescription)"
            }
        }
    }

    func removeStaleDuplicates() {
        let groups = exactDuplicateGroups + legacyDuplicateGroups
        let stale = groups.flatMap { group in
            group.sorted { $0.lastSeen > $1.lastSeen }.dropFirst()
        }
        guard !stale.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                for mac in stale { try await self.cloud.deleteDeviceData(for: mac.deviceID) }
                let staleIDs = Set(stale.map(\.deviceID))
                self.macs.removeAll { staleIDs.contains($0.deviceID) }
                self.showsDuplicateConfirmation = false
            } catch {
                self.issue = "Couldn’t finish duplicate cleanup. \(error.localizedDescription)"
            }
        }
    }
}

private struct CompanionDeviceManagerView: View {
    @ObservedObject var viewModel: CompanionDeviceManagerViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Macs").font(.title2.weight(.bold))
                    Text("Private iCloud device data").foregroundStyle(.secondary)
                }
                Spacer()
                Button { viewModel.reload() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading)
            }
            .padding(20)
            Divider()
            if let issue = viewModel.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(12)
            }
            if viewModel.hasDuplicateRecords {
                HStack {
                    Label("Duplicate records found", systemImage: "rectangle.on.rectangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Remove stale copies") { viewModel.showsDuplicateConfirmation = true }
                        .buttonStyle(.bordered)
                }
                .padding(14)
                Divider()
            }
            if viewModel.isLoading && viewModel.macs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.macs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No Macs in iCloud")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.macs) { mac in
                    CompanionDeviceRow(mac: mac) { viewModel.pendingRemoval = mac }
                }
                .listStyle(.inset)
            }
        }
        .alert("Remove this Mac?", isPresented: Binding(
            get: { viewModel.pendingRemoval != nil },
            set: { if !$0 { viewModel.pendingRemoval = nil } }
        ), presenting: viewModel.pendingRemoval) { mac in
            Button("Remove", role: .destructive) { viewModel.remove(mac) }
            Button("Cancel", role: .cancel) {}
        } message: { mac in
            Text("This removes its private iCloud status, history, and pending commands. It does not erase the Mac itself.")
        }
        .alert("Remove stale duplicates?", isPresented: $viewModel.showsDuplicateConfirmation) {
            Button("Remove stale copies", role: .destructive) { viewModel.removeStaleDuplicates() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The newest record in each duplicate group is kept. Exact hardware matches are safe; older records with only the same name are reviewed as legacy duplicates.")
        }
    }

}

private struct CompanionDeviceRow: View {
    let mac: CompanionMacStatus
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(mac.isStale ? Color.secondary : Color.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.displayName).fontWeight(.semibold)
                Text(buildAndLastSeen)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(telemetryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(mac.isStale ? "Offline" : "Online")
                .font(.caption.weight(.semibold))
                .foregroundStyle(mac.isStale ? Color.secondary : Color.green)
            Button("Remove", role: .destructive, action: remove)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var buildAndLastSeen: String { mac.build + " · " + lastSeenText(mac.lastSeen) }

    private var telemetryText: String {
        let battery = mac.batteryPercent.map { "\(Int($0.rounded()))% battery" } ?? "Battery unavailable"
        return battery + " · " + mac.thermalState.capitalized + " · " + "\(mac.activeSessionCount) sessions"
    }

    private func lastSeenText(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "seen now" }
        if seconds < 3_600 { return "seen \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "seen \(Int(seconds / 3_600))h ago" }
        return "seen \(Int(seconds / 86_400))d ago"
    }

}
