import Foundation

enum CompanionOperatorTests {
    static func run() {
        testPrivateProjectionAndContentBounds()
        testNamedOperationsUseIndexedItemsAndSharing()
    }

    private static func thread(now: Date = Date()) -> CodexThreadMirror {
        CodexThreadMirror(id: "local-thread-id", title: "Private project plan", preview: "private excerpt", cwd: "/private/work", projectName: "Private client",
            sectionID: "local-section", sectionName: "Work", sectionPosition: 0, isPinned: true, isArchived: false, status: .finished,
            latestTurnErrorCode: nil, updatedAt: now, startedAt: now.addingTimeInterval(-600), completedAt: now,
            messages: [CodexThreadMessage(id: "local-message-id", role: .user, text: "Private message text", createdAt: now)])
    }

    private static func testPrivateProjectionAndContentBounds() {
        let now = Date()
        let old = OperatorSession(id: "old", harnessID: "codex", harnessName: "Codex", state: .running,
            startedAt: now.addingTimeInterval(-86_400), endedAt: nil, lastActivityAt: now.addingTimeInterval(-85_000),
            inputTokens: 100, outputTokens: 20, reasoningTokens: 5, cachedTokens: 0)
        let snapshot = CompanionOperatorProjection.make(sessions: [old], threads: [thread(now: now)], skills: [], sources: [], workflowLanes: [:],
            sharingEnabled: false, triggersEnabled: true, diagnosticsEnabled: false, historyEnabled: true, now: now)
        expect(snapshot.sessions.first?.state == .unknown, "historical unclosed sessions are not currently active")
        let encoded = String(decoding: try! CompanionJSON.encoder.encode(snapshot), as: UTF8.self)
        expect(!encoded.contains("Private") && !encoded.contains("/private") && !encoded.contains("local-thread-id"), "disabled content sharing sends no titles, client names, messages, paths or local identifiers")
        expect(snapshot.threads.isEmpty && snapshot.skills.isEmpty, "sharing opt-in gates the catalog")
        let content = CompanionOperatorProjection.threadContent(thread(now: now))
        expect(content.messages.first?.text == "Private message text", "opening a shared chat returns actual messages")
        expect(content.itemID != "local-thread-id", "content uses a validated opaque lookup key")
        let huge = CompanionOperatorContent(itemID: "bounded", kind: "skill", title: "Large skill", text: String(repeating: "\u{0001}🧪", count: 100_000), messages: [], isTruncated: false).bounded()
        expect((try! CompanionJSON.encoder.encode(huge)).count <= 220_000, "Unicode and JSON escaping cannot exceed the content payload budget")
        expect(huge.isTruncated, "bounded content discloses omitted text")
    }

    private static func testNamedOperationsUseIndexedItemsAndSharing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-actions-" + UUID().uuidString)
        let suite = "CompanionOperatorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("SKILL.md")
            try "# Actual indexed skill\nUseful local instructions.".write(to: path, atomically: true, encoding: .utf8)
            let store = try OperatorStore(databaseURL: root.appendingPathComponent("Operator.sqlite"))
            try store.upsertSkills([OperatorSkill(id: "local-skill", sourceURL: path, name: "Indexed skill", sourceGroup: "Tests", fingerprint: "fixture", modifiedAt: Date())])
            let coordinator = OperatorCoordinator(store: store)
            var refreshes = 0
            var preferences: [String: Bool] = [:]
            let handler = CompanionOperatorRequestHandler(coordinator: coordinator, threads: { [thread()] }, defaults: defaults,
                refresh: { refreshes += 1 }, setPreference: { preferences[$0] = $1 }, didChange: {})
            let skillID = CompanionOperatorProjection.key("skill", "local-skill")
            expectThrows("content requests require sharing") { _ = try handler.handle(["operation": "readSkill", "itemID": skillID]) }
            _ = try handler.handle(["operation": "sharing", "enabled": "true"])
            let content = try handler.handle(["operation": "readSkill", "itemID": skillID])
            expect(content?.text?.contains("Actual indexed skill") == true, "reads the indexed skill, not caller-supplied paths")
            expectThrows("caller paths cannot access files") { _ = try handler.handle(["operation": "readSkill", "itemID": path.path]) }
            _ = try handler.handle(["operation": "favourite", "itemID": skillID, "enabled": "true"])
            _ = try handler.handle(["operation": "tags", "itemID": skillID, "tags": " Swift, Debugging,Swift "])
            expect(coordinator.skills().first?.metadata.isFavourite == true, "favourites persist in the same Mac Operator store")
            expect(coordinator.skills().first?.metadata.tags == ["Debugging", "Swift"], "tags use the Mac normalization and persistence")
            _ = try handler.handle(["operation": "recordUse", "itemID": skillID])
            expect(coordinator.skills().first?.useCount == 1, "skill usage updates the Mac catalog")
            let threadID = CompanionOperatorProjection.key("thread", "local-thread-id")
            _ = try handler.handle(["operation": "workflow", "itemID": threadID, "lane": "Doing"])
            expect(coordinator.threadWorkflowLanes()["local-thread-id"] == "Doing", "workflow moves persist on the Mac")
            expectThrows("unknown workflow lanes are rejected") { _ = try handler.handle(["operation": "workflow", "itemID": threadID, "lane": "execute arbitrary text"]) }
            expectThrows("unknown Codex sections are rejected") { _ = try handler.handle(["operation": "section", "itemID": threadID, "sectionID": "nonexistent"]) }
            expectThrows("unknown preference keys are rejected") { _ = try handler.handle(["operation": "preferences", "key": "anything", "enabled": "true"]) }
            _ = try handler.handle(["operation": "preferences", "key": "history", "enabled": "false"])
            expect(preferences["history"] == false, "only the named preference is changed")
            _ = try handler.handle(["operation": "refresh"])
            expect(refreshes == 1, "refresh uses the existing Mac ingestion path")
            _ = try handler.handle(["operation": "sharing", "enabled": "false"])
            expectThrows("revoking sharing immediately blocks further content reads") { _ = try handler.handle(["operation": "readThread", "itemID": threadID]) }
        } catch { fatalError("Operator command fixture failed: \(error)") }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("Test failed: \(message)") }
    }
    private static func expectThrows(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Test failed: \(message)") } catch { }
    }
}
