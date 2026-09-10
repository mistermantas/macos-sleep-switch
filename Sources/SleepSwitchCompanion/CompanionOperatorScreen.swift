import SwiftUI

struct CompanionOperatorScreen: View {
    let deviceID: String
    @ObservedObject var model: CompanionAppModel
    @State private var section = OperatorSection.overview
    @State private var search = ""
    @State private var harness = "All harnesses"
    @State private var project = "All projects"
    @State private var folder = ""
    @State private var boardStatus = "All statuses"
    @State private var source = "All sources"
    @State private var tag = "All tags"
    @State private var grouping = "Codex sections"
    @State private var liveOnly = true
    @State private var pinnedOnly = false
    @State private var includeArchived = false
    @State private var favouritesOnly = false
    @State private var showingSharing = false
    @State private var confirmSharing = false
    @State private var pendingAction: CompanionRemoteAction?

    init(deviceID: String, model: CompanionAppModel) {
        self.deviceID = deviceID
        self.model = model
        #if DEBUG
        let name = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--operator-section=") }?.split(separator: "=").last.map(String.init)
        _section = State(initialValue: name.flatMap(OperatorSection.init(rawValue:)) ?? .overview)
        #endif
    }

    private var mac: CompanionMacStatus? { model.macs.first { $0.deviceID == deviceID } }
    private var snapshot: CompanionOperatorSnapshot? { mac?.operatorSnapshot }
    private var canRequest: Bool { mac?.capabilities.canUseOperator == true && mac?.isStale == false && !model.commandInFlight }

    var body: some View {
        Group {
            if let mac {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(OperatorSection.allCases) { item in
                                Button { section = item; search = "" } label: {
                                    Label(item.rawValue, systemImage: item.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 13).padding(.vertical, 10)
                                        .background(section == item ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(section == item ? Color.white : Color.primary)
                                }
                                .accessibilityAddTraits(section == item ? .isSelected : [])
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    if mac.isStale {
                        Label("Offline · last updated \(CompanionTimeText.elapsed(since: mac.lastSeen))", systemImage: "wifi.slash")
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    content(mac)
                }
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom) {
                    if let progress = model.commandProgress, model.commandInFlight {
                        HStack { ProgressView(); Text(progress.actionTitle).font(.subheadline); Spacer() }
                            .padding().background(.regularMaterial)
                    } else if let issue = model.operatorIssues[deviceID] {
                        Label(issue, systemImage: "exclamationmark.circle").font(.footnote)
                            .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                    }
                }
            } else {
                ContentUnavailableView("Mac unavailable", systemImage: "laptopcomputer")
            }
        }
        .navigationTitle("Operator")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search \(section.rawValue.lowercased())")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                filters
                Button("Refresh", systemImage: "arrow.clockwise") {
                    if let mac, canRequest { model.sendOperator("refresh", to: mac) }
                    model.refresh()
                }.disabled(model.commandInFlight)
                Button("Sharing", systemImage: "icloud") { showingSharing = true }
            }
        }
        .refreshable { await model.refreshAndWait() }
        .sheet(isPresented: $showingSharing) {
            NavigationStack {
                Form {
                    Section {
                        Toggle("Chats and skills", isOn: Binding(get: { snapshot?.sharingEnabled == true }, set: { enabled in
                            if enabled { confirmSharing = true }
                            else if let mac { model.sendOperator("sharing", to: mac, parameters: ["enabled": "false"]) }
                        }))
                        .disabled(!canRequest)
                    } footer: {
                        Text("Sync chat titles, project names, and skill metadata through your private iCloud. Chat messages and skill text are sent only when you open them. You can turn sharing off here at any time.")
                    }
                    if mac?.capabilities.canUseOperator != true {
                        Section { Label("Update Sleep Switch on this Mac to enable Operator", systemImage: "arrow.down.app") }
                    }
                }
                .navigationTitle("Operator sharing").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showingSharing = false } }
                .confirmationDialog("Share chats and skills through your private iCloud?", isPresented: $confirmSharing, titleVisibility: .visible) {
                    Button("Enable sharing") { if let mac { model.sendOperator("sharing", to: mac, parameters: ["enabled": "true"]) } }
                }
            }
        }
        .confirmationDialog(pendingAction?.title ?? "Confirm", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let pendingAction, let mac {
                Button(pendingAction.title, role: pendingAction.isDestructive ? .destructive : nil) {
                    model.send(pendingAction, to: mac); self.pendingAction = nil
                }
            }
        }
    }

    @ViewBuilder private func content(_ mac: CompanionMacStatus) -> some View {
        switch section {
        case .overview: overview(mac)
        case .board:
            if snapshot?.sharingEnabled == true { board } else { sharingEmptyState }
        case .sessions: sessions
        case .skills:
            if snapshot?.sharingEnabled == true { skills } else { sharingEmptyState }
        case .machine:
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink { CompanionLiveMacView(deviceID: deviceID, model: model) { CompanionMacDetailScreen(mac: $0) } } label: { Label("Mac details", systemImage: "laptopcomputer").frame(maxWidth: .infinity, alignment: .leading) }
                        .padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                    ManualSessionCard(mac: mac, model: model)
                    PrimaryRemoteControls(mac: mac, model: model, confirm: { pendingAction = $0 })
                    CoolingControlCard(mac: mac, model: model)
                    NavigationLink { CompanionLiveMacView(deviceID: deviceID, model: model) { CompanionRemoteControlsScreen(mac: $0, model: model) } } label: { Label("All Mac controls", systemImage: "slider.horizontal.3") }
                }.padding(16)
            }
        case .automations:
            ScrollView {
                VStack(spacing: 16) {
                    AgentAutomationCard(mac: mac, model: model, confirm: { pendingAction = $0 })
                    if let snapshot {
                        VStack(spacing: 16) {
                            preferenceToggle("Agent triggers", key: "triggers", value: snapshot.triggersEnabled, mac: mac)
                            Divider()
                            preferenceToggle("Diagnostics", key: "diagnostics", value: snapshot.diagnosticsEnabled, mac: mac)
                            Divider()
                            preferenceToggle("Record history", key: "history", value: snapshot.historyEnabled, mac: mac)
                        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if let safety = mac.safety, mac.capabilities.canSetSafetyPreferences == true {
                        NavigationLink { CompanionLiveMacView(deviceID: deviceID, model: model) { latest in CompanionSafetyScreen(mac: latest, safety: latest.safety ?? safety, model: model) } } label: { Label("Lid-closed safety", systemImage: "shield.checkered") }
                    }
                }.padding(16)
            }
        }
    }

    private func overview(_ mac: CompanionMacStatus) -> some View {
        List {
            if let snapshot {
                Section {
                    HStack {
                        metric("Working", count: snapshot.sessions.filter { $0.state == .active }.count, symbol: "bolt.fill")
                        metric("Chats", count: snapshot.sharingEnabled ? snapshot.totalThreadCount : nil, symbol: "bubble.left.and.bubble.right")
                        metric("Needs you", count: snapshot.sharingEnabled ? snapshot.threads.filter { $0.state.requiresAttention }.count : nil, symbol: "exclamationmark.bubble")
                    }.padding(.vertical, 8)
                }
                Section("Harnesses") {
                    ForEach(snapshot.sources) { source in
                        HStack {
                            Label(source.name, systemImage: "terminal")
                            Spacer()
                            Text(source.status).foregroundStyle(source.status == "Ready" ? Color.secondary : .orange)
                        }
                    }
                }
                Section("Recent sessions") {
                    ForEach(snapshot.sessions.prefix(5)) { session in sessionLink(session) }
                    Button("All sessions") { section = .sessions; liveOnly = false }
                }
                Section {
                    Button { section = .board } label: { Label("Open board", systemImage: "rectangle.3.group.bubble") }
                    Button { section = .skills } label: { Label("Browse skills", systemImage: "wand.and.stars") }
                }
                Section { Label("Updated \(CompanionTimeText.elapsed(since: snapshot.updatedAt))", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            } else {
                Section {
                    ContentUnavailableView("Update the Mac app", systemImage: "arrow.down.app", description: Text("This Mac is sending summary data only. Install the latest Sleep Switch to browse Operator here."))
                }
                if let summary = mac.operatorSummary {
                    Section { LabeledContent("Previously reported sessions", value: "\(summary.activeSessionCount)") }
                }
            }
        }
    }

    private func metric(_ name: String, count: Int?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(count.map(String.init) ?? "—", systemImage: symbol).font(.title3.weight(.semibold))
            Text(name).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sharingEmptyState: some View {
        ContentUnavailableView {
            Label("Chats and skills", systemImage: "icloud")
        } description: {
            Text("Enable private iCloud sharing to browse this Mac’s Operator.")
        } actions: {
            Button("Sharing settings") { showingSharing = true }.buttonStyle(.borderedProminent)
        }
    }

    private var filteredThreads: [CompanionOperatorThread] {
        (snapshot?.threads ?? []).filter {
            (includeArchived || !$0.isArchived) && (!pinnedOnly || $0.isPinned)
            && (project == "All projects" || $0.projectName == project)
            && (folder.isEmpty || $0.folderID == folder)
            && (boardStatus == "All statuses" || $0.state.title == boardStatus)
            && matches([$0.title, $0.projectName ?? "", $0.sectionName ?? ""])
        }
    }

    private func lane(_ thread: CompanionOperatorThread) -> String {
        switch grouping {
        case "Status": thread.state.title
        case "Workflow": thread.workflowLane
        default: thread.sectionName ?? "No section"
        }
    }

    private var lanes: [String] { Array(Set(filteredThreads.map(lane))).sorted() }

    private var board: some View {
        GeometryReader { geometry in
            if geometry.size.width > 700 {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(lanes, id: \.self) { lane in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(lane).font(.headline).padding(.horizontal, 4)
                                ForEach(filteredThreads.filter { self.lane($0) == lane }) { thread in
                                    NavigationLink { CompanionOperatorThreadScreen(deviceID: deviceID, threadID: thread.id, model: model) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack {
                                                Circle().fill(thread.state.operatorTint).frame(width: 7, height: 7)
                                                Text(thread.state.title).font(.caption).foregroundStyle(.secondary)
                                                Spacer()
                                                if thread.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                                            }
                                            Text(thread.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                                            if let project = thread.projectName { Text(project).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                                    }.buttonStyle(.plain)
                                }
                            }.frame(maxHeight: .infinity, alignment: .top)
                        }
                    }.padding(20)
                    if filteredThreads.isEmpty { ContentUnavailableView.search(text: search) }
                }
            } else { boardList }
        }
    }

    private var boardList: some View {
        List {
            if filteredThreads.isEmpty { ContentUnavailableView.search(text: search) }
            ForEach(lanes, id: \.self) { lane in
                Section {
                    ForEach(filteredThreads.filter { self.lane($0) == lane }) { thread in
                        NavigationLink { CompanionOperatorThreadScreen(deviceID: deviceID, threadID: thread.id, model: model) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(thread.state.operatorTint).frame(width: 7, height: 7).padding(.top, 6)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(thread.title).font(.body.weight(.medium)).lineLimit(3)
                                    Text([thread.projectName, thread.activity?.title ?? thread.state.title].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if thread.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    }
                } header: { Text("\(lane) · \(filteredThreads.filter { self.lane($0) == lane }.count)") }
            }
            if let snapshot, snapshot.totalThreadCount > snapshot.threads.count {
                Text("Showing \(snapshot.threads.count) most recently updated chats of \(snapshot.totalThreadCount)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filteredSessions: [CompanionOperatorSession] {
        (snapshot?.sessions ?? []).filter {
            (!liveOnly || $0.state == .active) && (harness == "All harnesses" || harness == $0.harnessName)
            && matches([$0.title ?? "", $0.harnessName, $0.projectName ?? "", $0.state.title])
        }
    }

    private var sessions: some View {
        List {
            Section {
                Picker("Sessions", selection: $liveOnly) { Text("Live").tag(true); Text("Recent").tag(false) }.pickerStyle(.segmented)
            }
            if filteredSessions.isEmpty {
                ContentUnavailableView(liveOnly ? "No live sessions" : "No matching sessions", systemImage: "terminal")
            }
            ForEach(filteredSessions) { session in sessionLink(session) }
            if let snapshot, snapshot.totalSessionCount > snapshot.sessions.count {
                Text("Showing \(snapshot.sessions.count) recent sessions of \(snapshot.totalSessionCount)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sessionLink(_ session: CompanionOperatorSession) -> some View {
        NavigationLink { CompanionOperatorSessionScreen(deviceID: deviceID, sessionID: session.id, model: model) } label: {
            HStack(spacing: 10) {
                Circle().fill(session.state.operatorTint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title ?? session.harnessName).lineLimit(2)
                    Text(session.harnessName + " · " + session.state.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(CompanionOperatorFormatting.tokens(session.totalTokens)).font(.subheadline.monospacedDigit())
                    Text(CompanionOperatorFormatting.duration(session.durationSeconds)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 3)
        }
    }

    private var filteredSkills: [CompanionOperatorSkill] {
        (snapshot?.skills ?? []).filter {
            (!favouritesOnly || $0.isFavourite) && (source == "All sources" || source == $0.sourceGroup)
            && (tag == "All tags" || $0.tags.contains(tag)) && matches([$0.name, $0.sourceGroup] + $0.tags)
        }
    }

    private var skills: some View {
        List {
            if filteredSkills.isEmpty { ContentUnavailableView.search(text: search) }
            ForEach(filteredSkills) { skill in
                NavigationLink { CompanionOperatorSkillScreen(deviceID: deviceID, skillID: skill.id, model: model) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: skill.isFavourite ? "star.fill" : "wand.and.stars").foregroundStyle(skill.isFavourite ? Color.yellow : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name).fontWeight(.medium)
                            Text(([skill.sourceGroup] + skill.tags).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 4)
                }
                .swipeActions { Button(skill.isFavourite ? "Unfavourite" : "Favourite", systemImage: "star") {
                    if let mac { model.sendOperator("favourite", to: mac, parameters: ["itemID": skill.id, "enabled": String(!skill.isFavourite)]) }
                }.tint(.orange).disabled(!canRequest) }
            }
            if let snapshot, snapshot.totalSkillCount > snapshot.skills.count {
                Text("Showing \(snapshot.skills.count) skills of \(snapshot.totalSkillCount)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filters: some View {
        Menu {
            if section == .board {
                Picker("Group by", selection: $grouping) { ForEach(["Codex sections", "Status", "Workflow"], id: \.self) { Text($0) } }
                Picker("Project", selection: $project) { ForEach(["All projects"] + Array(Set(snapshot?.threads.compactMap(\.projectName) ?? [])).sorted(), id: \.self) { Text($0) } }
                Picker("Folder", selection: $folder) {
                    Text("All folders").tag("")
                    ForEach(boardFolders, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Status", selection: $boardStatus) {
                    ForEach(["All statuses"] + Array(Set(snapshot?.threads.map { $0.state.title } ?? [])).sorted(), id: \.self) { Text($0) }
                }
                Toggle("Pinned only", isOn: $pinnedOnly)
                Toggle("Include archived", isOn: $includeArchived)
            }
            if section == .sessions {
                Picker("Harness", selection: $harness) { ForEach(["All harnesses"] + Array(Set(snapshot?.sessions.map(\.harnessName) ?? [])).sorted(), id: \.self) { Text($0) } }
            }
            if section == .skills {
                Toggle("Favourites only", isOn: $favouritesOnly)
                Picker("Source", selection: $source) { ForEach(["All sources"] + Array(Set(snapshot?.skills.map(\.sourceGroup) ?? [])).sorted(), id: \.self) { Text($0) } }
                Picker("Tag", selection: $tag) { ForEach(["All tags"] + Array(Set(snapshot?.skills.flatMap(\.tags) ?? [])).sorted(), id: \.self) { Text($0) } }
            }
        } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
        .disabled(![OperatorSection.board, .sessions, .skills].contains(section))
    }

    private var boardFolders: [(id: String, name: String)] {
        var folders: [String: String] = [:]
        for thread in snapshot?.threads ?? [] {
            if let id = thread.folderID, let name = thread.folderName { folders[id] = name }
        }
        return folders.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    private func preferenceToggle(_ title: String, key: String, value: Bool, mac: CompanionMacStatus) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { model.sendOperator("preferences", to: mac, parameters: ["key": key, "enabled": String($0)]) })).disabled(!canRequest)
    }

    private func matches(_ values: [String]) -> Bool { search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) } }
}

private enum OperatorSection: String, CaseIterable, Identifiable {
    case overview = "Overview", board = "Board", sessions = "Sessions", skills = "Skills", machine = "Machine", automations = "Automations"
    var id: Self { self }
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

private extension CompanionWorkState {
    var operatorTint: Color {
        switch self {
        case .active: .green
        case .finished, .reviewReady: .blue
        case .failed, .blocked, .rateLimited: .orange
        default: .secondary
        }
    }
}

struct CompanionLiveMacView<Content: View>: View {
    let deviceID: String
    @ObservedObject var model: CompanionAppModel
    @ViewBuilder let content: (CompanionMacStatus) -> Content
    var body: some View {
        if let mac = model.macs.first(where: { $0.deviceID == deviceID }) { content(mac) }
        else { ContentUnavailableView("Mac unavailable", systemImage: "laptopcomputer") }
    }
}

private struct CompanionOperatorSessionScreen: View {
    let deviceID: String
    let sessionID: String
    @ObservedObject var model: CompanionAppModel
    private var session: CompanionOperatorSession? { model.macs.first { $0.deviceID == deviceID }?.operatorSnapshot?.sessions.first { $0.id == sessionID } }
    var body: some View {
        List {
            if let session {
                Section {
                    LabeledContent("Harness", value: session.harnessName)
                    LabeledContent("State", value: session.state.title)
                    LabeledContent("Started", value: session.startedAt.formatted())
                    LabeledContent("Last activity", value: session.updatedAt.formatted())
                    LabeledContent("Duration", value: CompanionOperatorFormatting.duration(session.durationSeconds))
                }
                Section("Tokens") {
                    LabeledContent("Input", value: session.inputTokens.formatted())
                    LabeledContent("Output", value: session.outputTokens.formatted())
                    LabeledContent("Reasoning", value: session.reasoningTokens.formatted())
                    LabeledContent("Cached", value: session.cachedTokens.formatted())
                }
                if let threadID = session.threadID {
                    NavigationLink("Open chat") { CompanionOperatorThreadScreen(deviceID: deviceID, threadID: threadID, model: model) }
                }
                if session.state == .unknown { Label("No recent activity confirmed by the Mac", systemImage: "clock.badge.questionmark").foregroundStyle(.secondary) }
            } else { ContentUnavailableView("Session unavailable", systemImage: "terminal") }
        }.navigationTitle(session?.title ?? "Session").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionOperatorThreadScreen: View {
    let deviceID: String
    let threadID: String
    @ObservedObject var model: CompanionAppModel
    private var mac: CompanionMacStatus? { model.macs.first { $0.deviceID == deviceID } }
    private var thread: CompanionOperatorThread? { mac?.operatorSnapshot?.threads.first { $0.id == threadID } }
    private var content: CompanionOperatorContent? { mac.flatMap { model.operatorContent(for: $0, itemID: threadID) } }
    var body: some View {
        List {
            if let thread, mac?.operatorSnapshot?.sharingEnabled == true {
                Section {
                    Text(thread.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    LabeledContent("Status", value: thread.state.title)
                    if let project = thread.projectName { LabeledContent("Project", value: project) }
                    LabeledContent("Section", value: thread.sectionName ?? "No section")
                    LabeledContent("Workflow", value: thread.workflowLane)
                }
                if let content {
                    if content.messages.isEmpty { ContentUnavailableView("No messages available", systemImage: "bubble.left.and.bubble.right") }
                    ForEach(content.messages) { message in
                        Section {
                            Text(message.text).textSelection(.enabled).font(.body)
                        } header: { Text((message.role == "user" ? "You" : "Agent") + " · " + message.createdAt.formatted(date: .omitted, time: .shortened)) }
                    }
                    if content.isTruncated { Text("Showing recent message excerpts").font(.caption).foregroundStyle(.secondary) }
                } else { contentLoading }
            } else { ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right") }
        }
        .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
        .task(id: thread?.updatedAt) {
            while model.commandInFlight && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, mac?.operatorSnapshot?.sharingEnabled == true else { return }
            load()
        }
        .toolbar {
            Menu {
                Button("Refresh messages", systemImage: "arrow.clockwise") { load() }
                Menu("Move to workflow") {
                    ForEach(["Inbox", "Planned", "Doing", "Waiting", "Done"], id: \.self) { lane in
                        Button(lane) { request("workflow", ["lane": lane]) }
                    }
                }
                Menu("Move to Codex section") {
                    Button("No section") { request("section", ["sectionID": "none"]) }
                    ForEach(sections, id: \.id) { section in Button(section.name) { request("section", ["sectionID": section.id]) } }
                }
            } label: { Label("Chat actions", systemImage: "ellipsis.circle") }
            .disabled(mac?.isStale != false || model.commandInFlight)
        }
    }
    private var sections: [(id: String, name: String)] {
        var values: [String: String] = [:]
        for thread in mac?.operatorSnapshot?.threads ?? [] { if let id = thread.sectionID { values[id] = thread.sectionName ?? "Section" } }
        return values.map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private var contentLoading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.commandInFlight { ProgressView("Loading messages from Mac") }
            else if let issue = model.operatorIssues[deviceID] { Label(issue, systemImage: "exclamationmark.circle") }
            else { Text(mac?.isStale == true ? "Mac is offline" : "Messages have not loaded yet").foregroundStyle(.secondary) }
            Button("Load messages") { load() }.disabled(mac?.isStale != false || model.commandInFlight)
        }
    }
    private func load() { if content == nil || !model.commandInFlight { request("readThread", [:]) } }
    private func request(_ operation: String, _ parameters: [String: String]) {
        guard let mac, !mac.isStale else { return }
        model.sendOperator(operation, to: mac, parameters: parameters.merging(["itemID": threadID]) { _, new in new })
    }
}

private struct CompanionOperatorSkillScreen: View {
    let deviceID: String
    let skillID: String
    @ObservedObject var model: CompanionAppModel
    @State private var tagDraft = ""
    @State private var editingTags = false
    private var mac: CompanionMacStatus? { model.macs.first { $0.deviceID == deviceID } }
    private var skill: CompanionOperatorSkill? { mac?.operatorSnapshot?.skills.first { $0.id == skillID } }
    private var content: CompanionOperatorContent? { mac.flatMap { model.operatorContent(for: $0, itemID: skillID) } }
    var body: some View {
        List {
            if let skill, mac?.operatorSnapshot?.sharingEnabled == true {
                Section {
                    Text(skill.name).font(.title3.weight(.semibold))
                    LabeledContent("Source", value: skill.sourceGroup)
                    LabeledContent("Uses", value: skill.useCount.formatted())
                    if !skill.tags.isEmpty { LabeledContent("Tags", value: skill.tags.joined(separator: ", ")) }
                }
                if let text = content?.text {
                    Section("Skill") { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    if content?.isTruncated == true { Text("Showing the first part of this skill").font(.caption).foregroundStyle(.secondary) }
                    Section {
                        Button("Copy skill", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        ShareLink(item: text, subject: Text(skill.name)) { Label("Share skill", systemImage: "square.and.arrow.up") }
                    }
                } else {
                    if model.commandInFlight { ProgressView("Loading skill from Mac") }
                    else if let issue = model.operatorIssues[deviceID] { Label(issue, systemImage: "exclamationmark.circle") }
                    Button("Load skill") { request("readSkill") }.disabled(mac?.isStale != false || model.commandInFlight)
                }
            } else { ContentUnavailableView("Skill unavailable", systemImage: "wand.and.stars") }
        }
        .navigationTitle("Skill").navigationBarTitleDisplayMode(.inline)
        .task(id: skill?.modifiedAt) {
            while model.commandInFlight && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, mac?.operatorSnapshot?.sharingEnabled == true else { return }
            request("readSkill")
        }
        .toolbar {
            if let skill {
                Button(skill.isFavourite ? "Unfavourite" : "Favourite", systemImage: skill.isFavourite ? "star.fill" : "star") { request("favourite", ["enabled": String(!skill.isFavourite)]) }
                    .disabled(mac?.isStale != false || model.commandInFlight)
                Menu {
                    Button("Edit tags", systemImage: "tag") { tagDraft = skill.tags.joined(separator: ", "); editingTags = true }
                    Button("Record use", systemImage: "checkmark") { request("recordUse") }
                    Button("Reload skill", systemImage: "arrow.clockwise") { request("readSkill") }
                } label: { Label("Skill actions", systemImage: "ellipsis.circle") }
                    .disabled(mac?.isStale != false || model.commandInFlight)
            }
        }
        .alert("Skill tags", isPresented: $editingTags) {
            TextField("Comma-separated tags", text: $tagDraft)
            Button("Save") { request("tags", ["tags": tagDraft]) }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func request(_ operation: String, _ parameters: [String: String] = [:]) {
        guard let mac, !mac.isStale else { return }
        model.sendOperator(operation, to: mac, parameters: parameters.merging(["itemID": skillID]) { _, new in new })
    }
}

#if DEBUG || targetEnvironment(simulator)
enum CompanionOperatorDemo {
    static func make(now: Date = Date()) -> CompanionOperatorSnapshot {
        CompanionOperatorSnapshot(updatedAt: now, sharingEnabled: true,
            sessions: [
                .init(id: "session-1", harnessID: "codex", harnessName: "Codex", state: .active, startedAt: now.addingTimeInterval(-1_200), updatedAt: now.addingTimeInterval(-10), durationSeconds: 1_190, inputTokens: 18_000, outputTokens: 2_400, reasoningTokens: 800, cachedTokens: 9_000, title: "Refine checkout review", projectName: "Storefront", threadID: "chat-1"),
                .init(id: "session-2", harnessID: "codex", harnessName: "Codex", state: .finished, startedAt: now.addingTimeInterval(-5_000), updatedAt: now.addingTimeInterval(-3_000), durationSeconds: 2_000, inputTokens: 9_000, outputTokens: 1_200, reasoningTokens: 300, cachedTokens: 4_000, title: "Improve account settings", projectName: "Storefront", threadID: "chat-2"),
                .init(id: "session-3", harnessID: "hermes", harnessName: "Hermes", state: .unknown, startedAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-84_000), durationSeconds: 2_400, inputTokens: 1_200, outputTokens: 300, reasoningTokens: 0, cachedTokens: 0, title: nil, projectName: nil, threadID: nil)
            ], threads: [
                .init(id: "chat-1", title: "Refine checkout review", projectName: "Storefront", sectionID: "section-1", sectionName: "Storefront", workflowLane: "Doing", isPinned: true, isArchived: false, state: .active, updatedAt: now, activity: .editingFiles),
                .init(id: "chat-2", title: "Improve account settings", projectName: "Storefront", sectionID: "section-1", sectionName: "Storefront", workflowLane: "Done", isPinned: false, isArchived: false, state: .finished, updatedAt: now.addingTimeInterval(-3_000), activity: nil),
                .init(id: "chat-3", title: "Review this week’s release", projectName: "Release", sectionID: "section-2", sectionName: "Release", workflowLane: "Waiting", isPinned: false, isArchived: false, state: .waiting, updatedAt: now.addingTimeInterval(-900), activity: nil)
            ], skills: [
                .init(id: "skill-1", name: "diagnosing-bugs", sourceGroup: "Agents", tags: ["Debugging", "Swift"], isFavourite: true, useCount: 4, modifiedAt: now),
                .init(id: "skill-2", name: "interface-review", sourceGroup: "Codex", tags: ["Design"], isFavourite: false, useCount: 2, modifiedAt: now)
            ], sources: [.init(id: "codex", name: "Codex", status: "Ready", capabilities: ["sessions", "tokenUsage"]), .init(id: "hermes", name: "Hermes", status: "Ready", capabilities: ["sessions"])],
            totalSessionCount: 3, totalThreadCount: 3, totalSkillCount: 2, triggersEnabled: true, diagnosticsEnabled: false, historyEnabled: true)
    }

    static func content(itemID: String) -> CompanionOperatorContent? {
        if itemID.hasPrefix("chat-") {
            return .init(itemID: itemID, kind: "thread", title: "Refine checkout review", text: nil, messages: [
                .init(id: "m1", role: "user", text: "Review the checkout on iPhone. Make the payment options easy to compare and keep the order total visible.", createdAt: Date().addingTimeInterval(-1_200)),
                .init(id: "m2", role: "agent", text: "The payment selection now stays visible above the total. I’m checking the narrow layout and the validation state before finishing.", createdAt: Date().addingTimeInterval(-30))
            ], isTruncated: false)
        }
        if itemID.hasPrefix("skill-") {
            return .init(itemID: itemID, kind: "skill", title: "diagnosing-bugs", text: "# Diagnosing bugs\n\nReproduce the reported behavior with a focused test. Trace the state change, apply the smallest complete fix, and verify the original scenario.\n\n## Verification\n\nCheck delayed responses, unavailable data, and recovery after a restart.", messages: [], isTruncated: false)
        }
        return nil
    }
}
#endif

#if DEBUG
struct CompanionOperatorPreview: View {
    let deviceID: String
    @ObservedObject var model: CompanionAppModel
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--operator-chat") {
            CompanionOperatorThreadScreen(deviceID: deviceID, threadID: "chat-1", model: model)
        } else if ProcessInfo.processInfo.arguments.contains("--operator-skill") {
            CompanionOperatorSkillScreen(deviceID: deviceID, skillID: "skill-1", model: model)
        } else {
            CompanionOperatorScreen(deviceID: deviceID, model: model)
        }
    }
}
#endif
