import Foundation

enum SharedContextIntakeTests {
    static func run() {
        testStagesAnExactPrivateCopy()
        testRejectsOversizedAndExpiredItems()
    }

    private static func testStagesAnExactPrivateCopy() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        let payload = Data("phone context".utf8)
        try? payload.write(to: source)
        let intake = SharedContextIntake(rootURL: root.appendingPathComponent("shared"))
        guard let draft = try? intake.stage(fileAt: source, now: Date(timeIntervalSince1970: 10)) else {
            fatalError("Test failed: stages a shared file")
        }
        expect(draft.filename == "source.pdf", "keeps a safe filename")
        expect(draft.byteCount == Int64(payload.count), "keeps exact byte count")
        guard let stagedURL = intake.fileURL(for: draft) else {
            fatalError("Test failed: resolves staged URL")
        }
        expect((try? Data(contentsOf: stagedURL)) == payload, "keeps an exact private copy")
        expect(intake.drafts(now: Date(timeIntervalSince1970: 11)) == [draft], "lists the staged receipt")
        intake.discard(draft)
        expect(intake.drafts(now: Date(timeIntervalSince1970: 11)).isEmpty, "discards only on explicit completion")
    }

    private static func testRejectsOversizedAndExpiredItems() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let intake = SharedContextIntake(rootURL: root.appendingPathComponent("shared"))
        let source = root.appendingPathComponent("source.txt")
        try? Data("x".utf8).write(to: source)
        guard let draft = try? intake.stage(fileAt: source, now: Date(timeIntervalSince1970: 10)) else {
            fatalError("Test failed: creates short-lived fixture")
        }
        expect(intake.drafts(now: draft.expiresAt.addingTimeInterval(1)).isEmpty, "expires stale shared context")
        let tooLarge = root.appendingPathComponent("too-large.bin")
        FileManager.default.createFile(atPath: tooLarge.path, contents: Data())
        if let handle = try? FileHandle(forWritingTo: tooLarge) {
            try? handle.truncate(atOffset: UInt64(SharedContextIntake.maximumBytes + 1))
            try? handle.close()
        }
        do {
            _ = try intake.stage(fileAt: tooLarge)
            fatalError("Test failed: oversized files cannot be staged")
        } catch let error as SharedContextIntakeError {
            expect(error == .fileTooLarge, "enforces the 25 MB share limit")
        } catch {
            fatalError("Test failed: unexpected oversize staging error")
        }
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            _ = try intake.stage(fileAt: directory)
            fatalError("Test failed: folders cannot be staged")
        } catch let error as SharedContextIntakeError {
            expect(error == .folderNotSupported, "rejects folder sharing")
        } catch {
            fatalError("Test failed: unexpected staging error")
        }
    }

    private static func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-switch-shared-context-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("Test failed: \(message)") }
    }
}
