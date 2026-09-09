import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OperatorMachineSnapshot: Equatable {
    let name: String
    let batteryPercent: Double?
    let powerSource: String
    let estimatedWatts: Double?
    let isCharging: Bool
    let chargingWatts: Double?
    let thermalState: String
    let temperatureCelsius: Double?
    let isKeepingAwake: Bool
    let keepsDisplayAwake: Bool
    let keepDisplayAwakePreference: Bool
    let awakeMode: String
    let awakeModeRaw: String
    let displayAsleep: Bool
    let coolingProfile: String?
    let availableCoolingProfiles: [String]
    let coolingState: String?
    let coolingMessage: String?
    let fanCount: Int
    let activeFanRPM: Int?
    let lidSafetyMessage: String
    let manualSessionEndsAt: Date?
}

struct OperatorAutomationSnapshot: Equatable {
    let keepsAwakeForAgents: Bool
    let wakeDisplayWhenFinished: Bool
    let finishAction: String?
    let activeAgentCount: Int
    let activeSessionCount: Int
    let agentNames: [String]
    let triggersEnabled: Bool
    let diagnosticsEnabled: Bool
    let historyEnabled: Bool
}

struct OperatorRemoteInboxSnapshot: Equatable {
    let rootURL: URL
    let items: [RemoteContextInboxItem]
}

struct OperatorActionHandlers {
    let connectCodex: () -> Void
    let toggleManualAwake: () -> Void
    let sleepDisplay: () -> Void
    let toggleAgentAwake: () -> Void
    let toggleWakeWhenFinished: () -> Void
    let toggleSleepWhenFinished: () -> Void
    let toggleShutdownWhenFinished: () -> Void
    let toggleKeepDisplayAwake: () -> Void
    let setAwakeMode: (String) -> Void
    let setCoolingProfile: (String) -> Void
    let toggleAgentTriggers: () -> Void
    let toggleDiagnostics: () -> Void
    let toggleHistory: () -> Void
    let showSettings: () -> Void
    let showInsights: () -> Void
    let showDiagnostics: () -> Void
}

struct OperatorWindowSnapshot: Equatable {
    let refreshedAt: Date?
    let adapterSnapshots: [OperatorAdapterSnapshot]
    let sessions: [OperatorSession]
    let codexThreads: [CodexThreadMirror]
    let threadWorkflowLanes: [String: String]
    let skills: [OperatorSkillRecord]
    let machine: OperatorMachineSnapshot
    let automations: OperatorAutomationSnapshot
    let remoteInbox: OperatorRemoteInboxSnapshot?
    let persistenceError: String?

    static let empty = OperatorWindowSnapshot(
        refreshedAt: nil,
        adapterSnapshots: [],
        sessions: [],
        codexThreads: [],
        threadWorkflowLanes: [:],
        skills: [],
        machine: OperatorMachineSnapshot(
            name: "This Mac",
            batteryPercent: nil,
            powerSource: "Unknown",
            estimatedWatts: nil,
            isCharging: false,
            chargingWatts: nil,
            thermalState: "unknown",
            temperatureCelsius: nil,
            isKeepingAwake: false,
            keepsDisplayAwake: false,
            keepDisplayAwakePreference: false,
            awakeMode: "Prevent sleep",
            awakeModeRaw: "preventSleep",
            displayAsleep: false,
            coolingProfile: nil,
            availableCoolingProfiles: [],
            coolingState: nil,
            coolingMessage: nil,
            fanCount: 0,
            activeFanRPM: nil,
            lidSafetyMessage: "Checking safety",
            manualSessionEndsAt: nil
        ),
        automations: OperatorAutomationSnapshot(
            keepsAwakeForAgents: false,
            wakeDisplayWhenFinished: false,
            finishAction: nil,
            activeAgentCount: 0,
            activeSessionCount: 0,
            agentNames: [],
            triggersEnabled: false,
            diagnosticsEnabled: false,
            historyEnabled: false
        ),
        remoteInbox: nil,
        persistenceError: nil
    )
}

@MainActor
final class OperatorViewModel: ObservableObject {
    enum SessionScope: String, CaseIterable, Identifiable {
        case live = "Live"
        case recent = "Recent"

        var id: String { rawValue }
    }

    enum BoardGrouping: String, CaseIterable, Identifiable {
        case status = "Status"
        case codexSection = "Codex sections"
        case workflow = "Workflow"

        var id: String { rawValue }
    }

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case board = "Board"
        case sessions = "Sessions"
        case skills = "Skills"
        case machine = "Machine"
        case automations = "Automations"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "circle.grid.2x2"
            case .board: "rectangle.3.group.bubble"
            case .sessions: "terminal"
            case .skills: "wand.and.stars"
            case .machine: "laptopcomputer"
            case .automations: "bolt.badge.automatic"
            }
        }
    }

    @Published var section: Section = .board
    @Published private(set) var snapshot: OperatorWindowSnapshot
    @Published var search = ""
    @Published var favouritesOnly = false
    @Published var selectedSourceGroup = "All sources"
    @Published var selectedTag = "All tags"
    @Published var selectedSkillID: String?
    @Published var tagDraft = ""
    @Published var sessionScope: SessionScope = .live
    @Published var selectedHarness = "All harnesses"
    @Published var selectedProject = "All projects"
    @Published var selectedDirectory = "All folders"
    @Published var selectedBoardStatus = "All statuses"
    @Published var pinnedThreadsOnly = false
    @Published var includesArchivedThreads = false
    @Published var selectedCodexThread: CodexThreadMirror?
    /// Codex sidebar sections are the default board because they are the
    /// user's intentional organization. Lifecycle status remains an optional
    /// operational view rather than replacing that structure.
    @Published var boardGrouping: BoardGrouping = .codexSection
    @Published var collapsedBoardLanes: Set<String> = []
    @Published private(set) var boardMoveIssue: String?
    private var pendingSectionLanes: [String: String] = [:]

    private let snapshotProvider: () -> OperatorWindowSnapshot
    private let refreshAction: () -> Void
    private let setFavourite: (Bool, String) throws -> Void
    private let replaceTags: ([String], String) throws -> Void
    private let recordUse: (SkillUseEvent) throws -> Void
    private let setThreadWorkflowLane: (String, String) throws -> Void
    private let moveCodexThread: (String, String?) throws -> Void
    let actions: OperatorActionHandlers

    init(
        snapshotProvider: @escaping () -> OperatorWindowSnapshot,
        refreshAction: @escaping () -> Void,
        setFavourite: @escaping (Bool, String) throws -> Void,
        replaceTags: @escaping ([String], String) throws -> Void,
        recordUse: @escaping (SkillUseEvent) throws -> Void,
        setThreadWorkflowLane: @escaping (String, String) throws -> Void,
        moveCodexThread: @escaping (String, String?) throws -> Void,
        actions: OperatorActionHandlers
    ) {
        self.snapshotProvider = snapshotProvider
        self.refreshAction = refreshAction
        self.setFavourite = setFavourite
        self.replaceTags = replaceTags
        self.recordUse = recordUse
        self.setThreadWorkflowLane = setThreadWorkflowLane
        self.moveCodexThread = moveCodexThread
        self.actions = actions
        snapshot = snapshotProvider()
    }

    var activeSessions: [OperatorSession] {
        snapshot.sessions.filter { $0.state == .running }
    }

    var recentSessions: [OperatorSession] {
        snapshot.sessions.sorted {
            ($0.lastActivityAt ?? $0.startedAt) > ($1.lastActivityAt ?? $1.startedAt)
        }
    }

    var displayedSessions: [OperatorSession] {
        sessionScope == .live ? activeSessions : recentSessions
    }

    func codexThread(for session: OperatorSession) -> CodexThreadMirror? {
        guard session.harnessID == "codex" else { return nil }
        return snapshot.codexThreads.first { $0.id == session.id }
    }

    var attentionItems: [String] {
        var items = snapshot.adapterSnapshots.compactMap { adapter -> String? in
            guard adapter.availability != .available else { return nil }
            if let issue = adapter.issue { return issue }
            return switch adapter.availability {
            case .permissionRequired: "\(adapter.harnessName) needs access"
            case .malformedSource: "\(adapter.harnessName) data needs attention"
            case .unavailable: "\(adapter.harnessName) is unavailable"
            case .available: nil
            }
        }
        if snapshot.persistenceError != nil { items.append("Operator’s local database needs attention") }
        return items
    }

    var boardHarnesses: [String] {
        ["All harnesses", "Codex"]
    }

    var boardProjects: [String] {
        ["All projects"] + Array(Set(snapshot.codexThreads.map(boardProjectName))).sorted()
    }

    var boardDirectories: [String] {
        ["All folders"] + Array(Set(snapshot.codexThreads.map(boardDirectoryName))).sorted()
    }

    private var boardStatusCandidates: [CodexThreadMirror] {
        snapshot.codexThreads
            .filter { includesArchivedThreads || !$0.isArchived }
            .filter { _ in selectedHarness == "All harnesses" || selectedHarness == "Codex" }
            .filter { selectedProject == "All projects" || boardProjectName($0) == selectedProject }
            .filter { selectedDirectory == "All folders" || boardDirectoryName($0) == selectedDirectory }
            .filter { !pinnedThreadsOnly || $0.isPinned }
    }

    var boardStatuses: [String] {
        ["All statuses"] + boardStateOrder.map(\.title)
            .filter { title in boardStatusCandidates.contains { workState(for: $0).title == title } }
    }

    var boardThreads: [CodexThreadMirror] {
        boardStatusCandidates
            .filter { selectedBoardStatus == "All statuses" || workState(for: $0).title == selectedBoardStatus }
            .sorted {
                if $0.boardLane != $1.boardLane { return $0.boardLane == "No section" }
                if $0.sectionPosition != $1.sectionPosition { return ($0.sectionPosition ?? Int.max) < ($1.sectionPosition ?? Int.max) }
                return $0.updatedAt > $1.updatedAt
            }
    }

    var boardLanes: [String] {
        switch boardGrouping {
        case .status:
            return boardStateOrder.map(\.title)
                .filter { lane in boardThreads.contains { boardLane(for: $0) == lane } }
        case .workflow:
            return workflowLanes.filter { lane in boardThreads.contains { boardLane(for: $0) == lane } }
        case .codexSection:
            return lanesForCodexSections
        }
    }

    private var lanesForCodexSections: [String] {
        let lanes = Array(Set(boardThreads.map { boardLane(for: $0) }))
        return lanes.sorted { leftLane, rightLane in
            if leftLane == "No section" { return false }
            if rightLane == "No section" { return true }
            let leftPosition = boardThreads.first(where: { thread in thread.boardLane == leftLane })?.sectionPosition ?? Int.max
            let rightPosition = boardThreads.first(where: { thread in thread.boardLane == rightLane })?.sectionPosition ?? Int.max
            if leftPosition != rightPosition { return leftPosition < rightPosition }
            return leftLane.localizedCaseInsensitiveCompare(rightLane) == .orderedAscending
        }
    }

    var workflowLanes: [String] {
        ["Inbox", "Planned", "Doing", "Waiting", "Done"]
    }

    var boardStateOrder: [CompanionWorkState] {
        [.active, .waiting, .rateLimited, .failed, .stopped, .finished, .unknown]
    }

    func workState(for thread: CodexThreadMirror) -> CompanionWorkState {
        thread.remoteWorkState(now: snapshot.refreshedAt ?? Date())
    }

    func workState(for session: OperatorSession) -> CompanionWorkState {
        session.remoteWorkState(now: snapshot.refreshedAt ?? Date())
    }

    func boardLane(for thread: CodexThreadMirror) -> String {
        switch boardGrouping {
        case .status: workState(for: thread).title
        case .codexSection: pendingSectionLanes[thread.id] ?? thread.boardLane
        case .workflow: snapshot.threadWorkflowLanes[thread.id] ?? "Inbox"
        }
    }

    func sectionID(for lane: String) -> String? {
        boardThreads.first { boardLane(for: $0) == lane }?.sectionID
    }

    func moveToCodexSection(_ lane: String, thread: CodexThreadMirror) {
        guard boardGrouping == .codexSection else { return }
        let targetSectionID = sectionID(for: lane)
        do {
            try moveCodexThread(thread.id, targetSectionID)
            pendingSectionLanes[thread.id] = lane
            boardMoveIssue = nil
            refreshAction()
        } catch {
            boardMoveIssue = error.localizedDescription
        }
    }

    func moveDroppedThread(_ threadID: String, toCodexSectionLane lane: String) {
        guard let thread = snapshot.codexThreads.first(where: { $0.id == threadID }) else { return }
        moveToCodexSection(lane, thread: thread)
    }

    func toggleCollapsedBoardLane(_ lane: String) {
        if collapsedBoardLanes.contains(lane) {
            collapsedBoardLanes.remove(lane)
        } else {
            collapsedBoardLanes.insert(lane)
        }
    }

    /// Codex does not currently expose a supported public deep link for a
    /// particular local thread. Focus its app when it is already running, or
    /// launch it otherwise; this is deliberately not implemented by touching
    /// Codex's private state database.
    func openInCodex(_ thread: CodexThreadMirror) {
        if let runningCodex = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.lastPathComponent == "Codex.app" || $0.localizedName == "Codex"
        }) {
            runningCodex.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        NSWorkspace.shared.open(appURL)
    }

    func moveToWorkflowLane(_ lane: String, thread: CodexThreadMirror) {
        try? setThreadWorkflowLane(lane, thread.id)
        snapshot = snapshotProvider()
    }

    func boardProjectName(_ thread: CodexThreadMirror) -> String {
        if let projectName = thread.projectName, !projectName.isEmpty { return projectName }
        let path = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "No project" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func boardDirectoryName(_ thread: CodexThreadMirror) -> String {
        let path = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "No folder" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var displayedSkills: [OperatorSkillRecord] {
        snapshot.skills.filter { record in
            (!favouritesOnly || record.metadata.isFavourite)
                && (selectedSourceGroup == "All sources" || record.skill.sourceGroup == selectedSourceGroup)
                && (selectedTag == "All tags" || record.metadata.tags.contains(selectedTag))
                && (search.isEmpty || record.skill.name.localizedCaseInsensitiveContains(search)
                    || record.metadata.tags.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var sourceGroups: [String] {
        ["All sources"] + Array(Set(snapshot.skills.map(\.skill.sourceGroup))).sorted()
    }

    var tags: [String] {
        ["All tags"] + Array(Set(snapshot.skills.flatMap(\.metadata.tags))).sorted()
    }

    var selectedSkill: OperatorSkillRecord? {
        snapshot.skills.first { $0.id == selectedSkillID }
    }

    func refresh() {
        refreshAction()
        snapshot = snapshotProvider()
        if selectedSkillID != nil, selectedSkill == nil { selectedSkillID = nil }
    }

    func perform(_ action: () -> Void) {
        action()
        snapshot = snapshotProvider()
    }

    func reloadAfterBackgroundRefresh() {
        snapshot = snapshotProvider()
        pendingSectionLanes = pendingSectionLanes.filter { threadID, lane in
            snapshot.codexThreads.first { $0.id == threadID }?.boardLane != lane
        }
    }

    func toggleFavourite(_ record: OperatorSkillRecord) {
        try? setFavourite(!record.metadata.isFavourite, record.id)
        snapshot = snapshotProvider()
    }

    func saveTags(for record: OperatorSkillRecord) {
        let tags = tagDraft.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try? replaceTags(tags, record.id)
        snapshot = snapshotProvider()
        tagDraft = selectedSkill?.metadata.tags.joined(separator: ", ") ?? ""
    }

    func select(_ record: OperatorSkillRecord) {
        selectedSkillID = record.id
        tagDraft = record.metadata.tags.joined(separator: ", ")
    }

    func copy(_ record: OperatorSkillRecord) {
        guard let text = try? String(contentsOf: record.skill.sourceURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        recordUse(for: record)
    }

    func reveal(_ record: OperatorSkillRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.skill.sourceURL])
        recordUse(for: record)
    }

    func export(_ record: OperatorSkillRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.skill.sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try FileManager.default.copyItem(at: record.skill.sourceURL, to: destination)
            recordUse(for: record)
        } catch {
            NSSound.beep()
        }
    }

    func share(_ record: OperatorSkillRecord) {
        guard let window = NSApp.keyWindow else { return }
        let picker = NSSharingServicePicker(items: [record.skill.sourceURL])
        picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
        recordUse(for: record)
    }

    private func recordUse(for record: OperatorSkillRecord) {
        try? recordUse(SkillUseEvent(
            id: UUID().uuidString,
            skillID: record.id,
            sessionID: activeSessions.first?.id,
            harnessID: activeSessions.first?.harnessID,
            occurredAt: Date()
        ))
        snapshot = snapshotProvider()
    }
}

@MainActor
final class OperatorWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: OperatorViewModel

    init(viewModel: OperatorViewModel) {
        self.viewModel = viewModel
        let view = OperatorWindow(viewModel: viewModel)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Operator · Sleep Switch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_060, height: 700))
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("OperatorWindow") { window.center() }
        window.setFrameAutosaveName("OperatorWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        viewModel.refresh()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-operator"), let screen = NSScreen.main {
            // Keep the debug preview in the obvious top-left work area. This is
            // deliberately preview-only; normal launches retain macOS centering.
            let visibleFrame = screen.visibleFrame
            let frame = window?.frame ?? .zero
            window?.setFrameOrigin(NSPoint(
                x: visibleFrame.minX + 80,
                y: visibleFrame.maxY - frame.height - 80
            ))
        }
#endif
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshFromBackground() { viewModel.reloadAfterBackgroundRefresh() }

    func windowWillClose(_ notification: Notification) {
    }
}

private struct OperatorWindow: View {
    @ObservedObject var viewModel: OperatorViewModel

    var body: some View {
        NavigationSplitView {
            List(OperatorViewModel.Section.allCases, selection: $viewModel.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Operator")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(headerStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { viewModel.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var headerStatus: String {
        guard let refreshedAt = viewModel.snapshot.refreshedAt else { return "Waiting for the first local scan" }
        return "Local data · updated \(refreshedAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private var content: some View {
        switch viewModel.section {
        case .overview: OperatorOverview(viewModel: viewModel)
        case .board: OperatorBoard(viewModel: viewModel)
        case .sessions: OperatorSessions(viewModel: viewModel)
        case .skills: OperatorSkills(viewModel: viewModel)
        case .machine: OperatorMachine(viewModel: viewModel)
        case .automations: OperatorAutomations(viewModel: viewModel)
        }
    }
}

private struct OperatorOverview: View {
    @ObservedObject var viewModel: OperatorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    OperatorMetricCard(title: "Working", value: "\(viewModel.boardThreads.filter { viewModel.workState(for: $0) == .active || viewModel.workState(for: $0) == .waiting }.count)", symbol: "bolt.fill", tint: .blue)
                    OperatorMetricCard(title: "Chats", value: "\(viewModel.boardThreads.count)", symbol: "bubble.left.and.bubble.right", tint: .purple)
                    OperatorMetricCard(title: "Needs you", value: "\(viewModel.boardThreads.filter { viewModel.workState(for: $0).requiresAttention }.count)", symbol: "exclamationmark.bubble", tint: .orange)
                }
                if !viewModel.attentionItems.isEmpty {
                    OperatorPanel(title: "Needs attention", symbol: "exclamationmark.triangle") {
                        ForEach(viewModel.attentionItems, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if viewModel.snapshot.adapterSnapshots.contains(where: { $0.harnessID == "codex" && $0.availability == .permissionRequired }) {
                    OperatorPanel(title: "Codex access", symbol: "folder.badge.plus") {
                        HStack {
                            Text("Choose your .codex folder to restore local sessions, chats, and skills.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Connect Codex…") { viewModel.actions.connectCodex() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                OperatorPanel(title: "Harnesses", symbol: "point.3.connected.trianglepath.dotted") {
                    if viewModel.snapshot.adapterSnapshots.isEmpty {
                        Text("Scanning local harnesses").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.snapshot.adapterSnapshots, id: \.harnessID) { adapter in
                            let liveCount = viewModel.activeSessions.filter { $0.harnessID == adapter.harnessID }.count
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(adapter.availability == .available ? .green : .orange)
                                    .frame(width: 8, height: 8)
                                Text(adapter.harnessName).fontWeight(.medium)
                                Text(adapter.capabilities.filter(\.isSupported).map { $0.kind.rawValue }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(adapter.availability == .available && liveCount > 0
                                     ? "\(liveCount) live" : adapter.availability.displayTitle)
                                    .foregroundStyle(adapter.availability == .available && liveCount > 0 ? .blue : .secondary)
                                    .monospacedDigit()
                                    .help([adapter.issue, adapter.diagnostic].compactMap { $0 }.joined(separator: "\n"))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Button("Open board") { viewModel.section = .board }
                        Spacer()
                        Button("Browse skills") { viewModel.section = .skills }
                    }
                    .buttonStyle(.bordered)
                }
                OperatorPanel(title: "Recent activity", symbol: "clock.arrow.circlepath") {
                    if viewModel.recentSessions.isEmpty {
                        Text("No local session activity yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.recentSessions.prefix(4))) { session in
                            let state = viewModel.workState(for: session)
                            HStack(spacing: 10) {
                                Circle().fill(operatorWorkStateTint(state)).frame(width: 7, height: 7)
                                Text(session.harnessName).fontWeight(.medium)
                                Text(state.title).foregroundStyle(.secondary)
                                Spacer()
                                Text(lastActivityText(session)).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                if let remoteInbox = viewModel.snapshot.remoteInbox {
                    OperatorPanel(title: "Remote Inbox", symbol: "tray.and.arrow.down.fill") {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(remoteInbox.items.isEmpty ? "No received items" : "\(remoteInbox.items.count) recent deliveries")
                                    .fontWeight(.medium)
                                if let latest = remoteInbox.items.first {
                                    Text("Latest \(relativeTime(latest.receivedAt)) ago")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Review") { viewModel.section = .machine }
                                .buttonStyle(.bordered)
                            Button("Reveal folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([remoteInbox.rootURL])
                            }
                            .buttonStyle(.bordered)
                        }
                        if !remoteInbox.items.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(Array(remoteInbox.items.prefix(3))) { item in
                                    HStack(spacing: 10) {
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.filename)
                                                .lineLimit(1)
                                                .fontWeight(.medium)
                                            Text("\(formatByteCount(item.byteCount)) · \(relativeTime(item.receivedAt)) ago")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Reveal") {
                                            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                                        }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct OperatorBoard: View {
    @ObservedObject var viewModel: OperatorViewModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if !viewModel.snapshot.codexThreads.isEmpty {
                    board
                } else {
                    OperatorEmptyState(
                        title: viewModel.snapshot.codexThreads.isEmpty && !viewModel.snapshot.adapterSnapshots.isEmpty
                            ? "No Codex chats available yet"
                            : "Scanning your local Codex catalog",
                        symbol: "rectangle.3.group.bubble"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if let thread = viewModel.selectedCodexThread {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selectedCodexThread = nil }

                CodexThreadDetail(
                    thread: thread,
                    project: viewModel.boardProjectName(thread),
                    dismiss: { viewModel.selectedCodexThread = nil },
                    openInCodex: { viewModel.openInCodex(thread) }
                )
                .frame(maxWidth: 720, maxHeight: 640)
                .padding(36)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("Codex", systemImage: "terminal")
                .font(.headline)
            Text("\(viewModel.boardThreads.count) chats")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Group cards by", selection: $viewModel.boardGrouping) {
                    ForEach(OperatorViewModel.BoardGrouping.allCases) { grouping in
                        Text(grouping.rawValue).tag(grouping)
                    }
                }
            } label: {
                Label(viewModel.boardGrouping.rawValue, systemImage: "rectangle.3.group")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Picker("Harness", selection: $viewModel.selectedHarness) {
                    ForEach(viewModel.boardHarnesses, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label(viewModel.selectedHarness, systemImage: "point.3.connected.trianglepath.dotted")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Picker("Project", selection: $viewModel.selectedProject) {
                    ForEach(viewModel.boardProjects, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label(viewModel.selectedProject, systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Picker("Folder", selection: $viewModel.selectedDirectory) {
                    ForEach(viewModel.boardDirectories, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label(viewModel.selectedDirectory, systemImage: "folder.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            Menu {
                Picker("Status", selection: $viewModel.selectedBoardStatus) {
                    ForEach(viewModel.boardStatuses, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label(viewModel.selectedBoardStatus, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            Toggle("Pinned", isOn: $viewModel.pinnedThreadsOnly)
                .toggleStyle(.checkbox)
            Toggle("Archived", isOn: $viewModel.includesArchivedThreads)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private var board: some View {
        VStack(spacing: 0) {
            if let issue = viewModel.boardMoveIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            ScrollView([.horizontal, .vertical]) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(viewModel.boardLanes, id: \.self) { lane in
                        OperatorBoardLane(
                            name: lane,
                            threads: viewModel.boardThreads.filter { viewModel.boardLane(for: $0) == lane },
                            projectName: viewModel.boardProjectName,
                            select: { viewModel.selectedCodexThread = $0 },
                            workflowLanes: viewModel.workflowLanes,
                            allowsWorkflowMoves: viewModel.boardGrouping == .workflow,
                            allowsCodexSectionMoves: viewModel.boardGrouping == .codexSection,
                            isCollapsed: viewModel.collapsedBoardLanes.contains(lane),
                            toggleCollapsed: { viewModel.toggleCollapsedBoardLane(lane) },
                            move: { lane, thread in viewModel.moveToWorkflowLane(lane, thread: thread) },
                            moveDroppedThread: { viewModel.moveDroppedThread($0, toCodexSectionLane: lane) }
                        )
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct OperatorBoardLane: View {
    let name: String
    let threads: [CodexThreadMirror]
    let projectName: (CodexThreadMirror) -> String
    let select: (CodexThreadMirror) -> Void
    let workflowLanes: [String]
    let allowsWorkflowMoves: Bool
    let allowsCodexSectionMoves: Bool
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let move: (String, CodexThreadMirror) -> Void
    let moveDroppedThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(name).font(.headline)
                Text("\(threads.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: toggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand column" : "Collapse column")
            }
            if !isCollapsed {
                ForEach(threads) { thread in
                    OperatorBoardCard(
                        thread: thread,
                        project: projectName(thread),
                        workflowLanes: workflowLanes,
                        allowsWorkflowMoves: allowsWorkflowMoves,
                        allowsCodexSectionMoves: allowsCodexSectionMoves,
                        select: { select(thread) },
                        move: { move($0, thread) }
                    )
                }
            }
        }
        .frame(width: isCollapsed ? 148 : 300, alignment: .leading)
        .padding(8)
        .background(.tertiary.opacity(0.22), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrop(of: [UTType.text.identifier], isTargeted: nil) { providers in
            guard allowsCodexSectionMoves,
                  let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let threadID = object as? String else { return }
                DispatchQueue.main.async { moveDroppedThread(threadID) }
            }
            return true
        }
    }
}

private struct OperatorBoardCard: View {
    let thread: CodexThreadMirror
    let project: String
    let workflowLanes: [String]
    let allowsWorkflowMoves: Bool
    let allowsCodexSectionMoves: Bool
    let select: () -> Void
    let move: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: select) {
                cardContent
            }
            .buttonStyle(.plain)
            if allowsWorkflowMoves {
                Menu {
                    ForEach(workflowLanes, id: \.self) { lane in
                        Button("Move to \(lane)") { move(lane) }
                    }
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .menuStyle(.borderlessButton)
                .help("Move to workflow lane")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag {
            allowsCodexSectionMoves
                ? NSItemProvider(object: thread.id as NSString)
                : NSItemProvider()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Text(thread.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let activity = thread.recentActivity {
                    Image(systemName: activity.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(activity.title)
                }
                OperatorThreadStatus(state: thread.remoteWorkState())
            }
            if !thread.preview.isEmpty {
                Text(thread.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            if let note = thread.remoteWorkNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(operatorWorkStateTint(thread.remoteWorkState()))
            }
            HStack(spacing: 6) {
                Image(systemName: thread.isPinned ? "pin.fill" : "folder")
                    .font(.caption2)
                Text(thread.sectionName ?? project)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(relativeTime(thread.updatedAt))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OperatorThreadStatus: View {
    let state: CompanionWorkState

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var label: String {
        state.title
    }

    private var tint: Color {
        operatorWorkStateTint(state)
    }
}

private struct CodexThreadDetail: View {
    let thread: CodexThreadMirror
    let project: String
    let dismiss: () -> Void
    let openInCodex: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(thread.title).font(.title2.weight(.bold))
                    Text(project).foregroundStyle(.secondary)
                }
                Spacer()
                OperatorThreadStatus(state: thread.remoteWorkState())
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Close")
            }
            .padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Button(action: openInCodex) {
                    Label("Open in Codex", systemImage: "arrow.up.forward.app")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !thread.cwd.isEmpty {
                    Label(thread.cwd, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let note = thread.remoteWorkNote {
                    Label(note, systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(operatorWorkStateTint(thread.remoteWorkState()))
                }

                if let activity = thread.recentActivity {
                    Label(activity.title, systemImage: activity.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !thread.preview.isEmpty {
                    Text(thread.preview)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !thread.messages.isEmpty {
                    DisclosureGroup("Recent local excerpts") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(thread.messages) { message in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(message.role == .user ? "You" : "Codex")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(message.role == .user ? .blue : .secondary)
                                        Text(message.text)
                                            .font(.callout)
                                            .textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                        .frame(maxHeight: 230)
                        .padding(.top, 8)
                    }
                    .font(.callout.weight(.medium))
                }
            }
            .padding(24)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
        .accessibilityAddTraits(.isModal)
    }
}

private struct OperatorSessions: View {
    @ObservedObject var viewModel: OperatorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Sessions", selection: $viewModel.sessionScope) {
                    ForEach(OperatorViewModel.SessionScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
                Text(viewModel.sessionScope == .live ? "Live local work" : "Latest local sessions")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            if viewModel.displayedSessions.isEmpty {
                OperatorEmptyState(
                    title: viewModel.sessionScope == .live ? "No live local sessions" : "No local sessions yet",
                    symbol: "terminal"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.displayedSessions) { session in
                    let state = viewModel.workState(for: session)
                    let thread = viewModel.codexThread(for: session)
                    HStack(spacing: 12) {
                        Circle().fill(operatorWorkStateTint(state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread?.title ?? session.harnessName).fontWeight(.semibold).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(thread?.projectName ?? session.harnessName)
                                Text("·")
                                Text(thread?.recentActivity?.title ?? state.title)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        Text(formatDuration(session.durationSeconds)).foregroundStyle(.secondary).monospacedDigit()
                        Text(lastActivityText(session)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

private struct OperatorSkills: View {
    @ObservedObject var viewModel: OperatorViewModel

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    skillFilters
                    Divider()
                    if viewModel.displayedSkills.isEmpty {
                        OperatorEmptyState(title: "No skills match these filters", symbol: "wand.and.stars")
                    } else {
                        List(viewModel.displayedSkills) { record in
                            skillRow(record)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(width: min(max(proxy.size.width * 0.37, 310), 410))
                .frame(maxHeight: .infinity)
                Divider()
                skillDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skillFilters: some View {
        HStack(spacing: 8) {
            TextField("Filter skills", text: $viewModel.search)
            Menu {
                Picker("Source", selection: $viewModel.selectedSourceGroup) {
                    ForEach(viewModel.sourceGroups, id: \.self) { Text($0).tag($0) }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            .help("Filter source")
            Menu {
                Picker("Tag", selection: $viewModel.selectedTag) {
                    ForEach(viewModel.tags, id: \.self) { Text($0).tag($0) }
                }
            } label: { Image(systemName: "tag") }
            .help("Filter tag")
            Toggle(isOn: $viewModel.favouritesOnly) { Image(systemName: "star.fill") }
                .toggleStyle(.button)
                .help("Favourites only")
        }
        .padding(14)
    }

    private func skillRow(_ record: OperatorSkillRecord) -> some View {
        Button { viewModel.select(record) } label: {
            HStack(spacing: 10) {
                Image(systemName: record.metadata.isFavourite ? "star.fill" : "wand.and.stars")
                    .foregroundStyle(record.metadata.isFavourite ? .yellow : .blue)
                Text(record.skill.name).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                if record.useCount > 0 {
                    Text("\(record.useCount)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(viewModel.selectedSkillID == record.id ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    @ViewBuilder private var skillDetail: some View {
        if let record = viewModel.selectedSkill {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.skill.name).font(.title2.weight(.bold))
                        Text("\(record.skill.sourceGroup) · \(record.useCount) uses")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { viewModel.toggleFavourite(record) } label: {
                        Image(systemName: record.metadata.isFavourite ? "star.fill" : "star")
                    }
                    .buttonStyle(.bordered)
                }
                OperatorPanel(title: "Tags", symbol: "tag") {
                    TextField("Tags, separated by commas", text: $viewModel.tagDraft)
                    HStack {
                        Button("Save tags") { viewModel.saveTags(for: record) }
                        Spacer()
                        Text("Local only").foregroundStyle(.secondary)
                    }
                }
                OperatorPanel(title: "Use", symbol: "square.and.arrow.up") {
                HStack {
                    Button("Copy") { viewModel.copy(record) }
                    Button("Reveal") { viewModel.reveal(record) }
                    Button("Export") { viewModel.export(record) }
                    Button("Share") { viewModel.share(record) }
                }
                .buttonStyle(.bordered)
                }
                }
                .padding(24)
            }
        } else {
            OperatorEmptyState(title: "Choose a skill", symbol: "wand.and.stars")
        }
    }
}

private struct OperatorMachine: View {
    @ObservedObject var viewModel: OperatorViewModel

    private var snapshot: OperatorMachineSnapshot { viewModel.snapshot.machine }
    private var remoteInbox: OperatorRemoteInboxSnapshot? { viewModel.snapshot.remoteInbox }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    OperatorMetricCard(title: "Battery", value: snapshot.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "—", symbol: "battery.100", tint: .green)
                    OperatorMetricCard(title: "Thermal", value: snapshot.thermalState.capitalized, symbol: "thermometer.medium", tint: thermalTint)
                    OperatorMetricCard(title: "Awake", value: snapshot.isKeepingAwake ? "On" : "Off", symbol: "cup.and.saucer.fill", tint: snapshot.isKeepingAwake ? .blue : .secondary)
                }
                OperatorPanel(title: snapshot.name, symbol: "laptopcomputer") {
                    OperatorKeyValueGrid(items: [
                        ("Power", snapshot.powerSource.capitalized),
                        ("Load", snapshot.estimatedWatts.map { String(format: "%.1f W", $0) } ?? "—"),
                        ("Charging", snapshot.isCharging ? (snapshot.chargingWatts.map { String(format: "%.1f W", $0) } ?? "Charging") : "Not charging"),
                        ("Display", snapshot.displayAsleep ? "Asleep" : "On"),
                        ("Awake mode", snapshot.awakeMode),
                        ("Display awake", snapshot.keepsDisplayAwake ? "On" : "Off")
                    ])
                }
                OperatorPanel(title: "Thermals", symbol: "fan") {
                    OperatorKeyValueGrid(items: [
                        ("Temperature", snapshot.temperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? "No reading"),
                        ("Cooling", snapshot.coolingProfile ?? "System control"),
                        ("State", snapshot.coolingState ?? "Unavailable"),
                        ("Fans", snapshot.fanCount == 0 ? "No reading" : "\(snapshot.fanCount)"),
                        ("Active RPM", snapshot.activeFanRPM.map { "\($0) RPM" } ?? "—")
                    ])
                    if let message = snapshot.coolingMessage { Text(message).foregroundStyle(.secondary) }
                }
                OperatorPanel(title: "Mode", symbol: "slider.horizontal.3") {
                    HStack {
                        Text("Awake mode")
                        Spacer()
                        Menu(snapshot.awakeMode) {
                            Button("Prevent sleep") { viewModel.perform { viewModel.actions.setAwakeMode("preventSleep") } }
                            Button("Prevent sleep even with lid closed") { viewModel.perform { viewModel.actions.setAwakeMode("lidClosed") } }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    OperatorSwitchRow(title: "Keep display awake", isOn: snapshot.keepDisplayAwakePreference) {
                        viewModel.perform(viewModel.actions.toggleKeepDisplayAwake)
                    }
                    if !snapshot.availableCoolingProfiles.isEmpty {
                        HStack {
                            Text("Cooling profile")
                            Spacer()
                            Menu(snapshot.coolingProfile ?? "System control") {
                                ForEach(snapshot.availableCoolingProfiles, id: \.self) { profile in
                                    Button(profile.replacingOccurrences(of: "systemControl", with: "System Control").capitalized) {
                                        viewModel.perform { viewModel.actions.setCoolingProfile(profile) }
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                }
                OperatorPanel(title: "Controls", symbol: "switch.2") {
                    HStack {
                        Button(snapshot.isKeepingAwake ? "Stop keeping awake" : "Keep awake") {
                            viewModel.perform(viewModel.actions.toggleManualAwake)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Sleep display") { viewModel.perform(viewModel.actions.sleepDisplay) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Settings…") { viewModel.actions.showSettings() }
                    }
                    if let end = snapshot.manualSessionEndsAt {
                        Text("Manual session ends \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                OperatorPanel(title: "Lid-closed safety", symbol: "shield.lefthalf.filled") {
                    Text(snapshot.lidSafetyMessage).foregroundStyle(.secondary)
                }
                if let remoteInbox {
                    OperatorPanel(title: "Remote Inbox", symbol: "tray.and.arrow.down.fill") {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(remoteInbox.items.isEmpty ? "No received items" : "\(remoteInbox.items.count) files ready for review")
                                    .fontWeight(.medium)
                            }
                            Spacer()
                            Button("Reveal folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([remoteInbox.rootURL])
                            }
                            .buttonStyle(.bordered)
                        }

                        if remoteInbox.items.isEmpty {
                            Text("No items ready for review.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(remoteInbox.items) { item in
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(.blue)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.filename)
                                                .fontWeight(.medium)
                                                .lineLimit(1)
                                            Text("\(formatByteCount(item.byteCount)) · received \(relativeTime(item.receivedAt)) ago")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Reveal") {
                                            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var thermalTint: Color {
        switch snapshot.thermalState.lowercased() {
        case "nominal": .green
        case "fair": .yellow
        default: .orange
        }
    }
}

private struct OperatorAutomations: View {
    @ObservedObject var viewModel: OperatorViewModel

    private var snapshot: OperatorAutomationSnapshot { viewModel.snapshot.automations }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OperatorPanel(title: "Agent automation", symbol: "bolt.badge.automatic") {
                    OperatorSwitchRow(title: "Keep awake for agents", isOn: snapshot.keepsAwakeForAgents) {
                        viewModel.perform(viewModel.actions.toggleAgentAwake)
                    }
                    OperatorSwitchRow(title: "Wake display when agents finish", isOn: snapshot.wakeDisplayWhenFinished) {
                        viewModel.perform(viewModel.actions.toggleWakeWhenFinished)
                    }
                    Divider()
                    HStack {
                        Text(snapshot.activeSessionCount == 1 ? "1 live session" : "\(snapshot.activeSessionCount) live sessions")
                        Spacer()
                        Text(snapshot.agentNames.isEmpty ? "No harnesses active" : snapshot.agentNames.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                OperatorPanel(title: "When the work ends", symbol: "clock.badge.checkmark") {
                    HStack {
                        Button(snapshot.finishAction == "sleepMacWhenAgentsFinish" ? "Cancel sleep" : "Sleep Mac") {
                            viewModel.perform(viewModel.actions.toggleSleepWhenFinished)
                        }
                        .buttonStyle(.bordered)
                        Button(snapshot.finishAction == "shutdownMacWhenAgentsFinish" ? "Cancel shutdown" : "Shut down Mac") {
                            viewModel.perform(viewModel.actions.toggleShutdownWhenFinished)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    if let action = snapshot.finishAction {
                        Label(action == "shutdownMacWhenAgentsFinish" ? "Shutdown is queued" : "Sleep is queued", systemImage: "clock.badge.checkmark")
                            .foregroundStyle(.orange)
                    }
                }
                OperatorPanel(title: "Observability", symbol: "waveform.path.ecg") {
                    OperatorSwitchRow(title: "Agent triggers", isOn: snapshot.triggersEnabled) {
                        viewModel.perform(viewModel.actions.toggleAgentTriggers)
                    }
                    OperatorSwitchRow(title: "Detection diagnostics", isOn: snapshot.diagnosticsEnabled) {
                        viewModel.perform(viewModel.actions.toggleDiagnostics)
                    }
                    OperatorSwitchRow(title: "Save local insights", isOn: snapshot.historyEnabled) {
                        viewModel.perform(viewModel.actions.toggleHistory)
                    }
                    HStack {
                        Button("Open insights") { viewModel.actions.showInsights() }
                        Button("Detection diagnostics") { viewModel.actions.showDiagnostics() }
                        Spacer()
                        Button("Settings…") { viewModel.actions.showSettings() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
    }
}

private struct OperatorPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OperatorMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OperatorKeyValueGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1).fontWeight(.semibold).monospacedDigit()
                }
            }
        }
    }
}

private struct OperatorSwitchRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
        }
    }
}

private struct OperatorStatusRow: View {
    let title: String
    let value: String
    let isGood: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(isGood ? .green : .secondary)
        }
    }
}

private struct OperatorEmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline).foregroundStyle(.secondary)
        }
    }
}

private func operatorWorkStateTint(_ state: CompanionWorkState) -> Color {
    switch state {
    case .active:
        .blue
    case .waiting:
        .yellow
    case .rateLimited:
        .orange
    case .failed:
        .red
    case .stopped:
        .secondary
    case .finished, .reviewReady:
        .green
    case .stalled, .blocked:
        .orange
    case .unknown:
        .secondary
    }
}

private func formatTokens(_ value: Int) -> String {
    value >= 1_000 ? "\(String(format: "%.1f", Double(value) / 1_000))k" : "\(value)"
}

private func formatByteCount(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return total >= 3_600 ? "\(total / 3_600)h \((total % 3_600) / 60)m" : "\(total / 60)m"
}

private func lastActivityText(_ session: OperatorSession) -> String {
    let date = session.lastActivityAt ?? session.endedAt ?? session.startedAt
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
    return "\(Int(seconds / 86_400))d ago"
}

private func relativeTime(_ date: Date) -> String {
    guard date != .distantPast else { return "—" }
    let seconds = max(0, Date().timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
    return "\(Int(seconds / 86_400))d"
}
