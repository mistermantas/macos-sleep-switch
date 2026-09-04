import Foundation

enum RemoteContextInboxTests {
    static func run() {
        testReceivesOneSafeCopy()
        testRejectsExpiredTransfer()
        testRejectsEmptyAsset()
        testListsNewestItemsFirstAndIgnoresNoise()
        testPlacesAnExplicitCopyWithoutOverwriting()
    }

    private static func testReceivesOneSafeCopy() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("upload-source")
        try? Data("private context".utf8).write(to: source)
        let transfer = makeTransfer(filename: "../reference:notes?.pdf")
        let inbox = RemoteContextInbox(rootURL: root.appendingPathComponent("inbox"))

        let received = inbox.receive(transfer, assetURL: source)
        let destination = inbox.rootURL
            .appendingPathComponent(transfer.id.uuidString)
            .appendingPathComponent("reference_notes_.pdf")

        expect(received.accepted, "accepts a bounded, unexpired context item")
        expect(FileManager.default.fileExists(atPath: destination.path), "writes only inside the private inbox")
        expect(
            (try? Data(contentsOf: destination)) == Data("private context".utf8),
            "copies the item without altering its contents"
        )
        expect(
            inbox.items().map(\.filename) == ["reference_notes_.pdf"],
            "surfaces one completed receipt without traversing arbitrary files"
        )

        let repeated = inbox.receive(transfer, assetURL: source)
        expect(repeated.accepted, "treats a repeated delivery as idempotent")
        expect(repeated.message == "Already received.", "does not duplicate a replayed transfer")
    }

    private static func testRejectsExpiredTransfer() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("upload-source")
        try? Data("private context".utf8).write(to: source)
        let expired = makeTransfer(
            filename: "context.txt",
            expiresAt: Date().addingTimeInterval(-1)
        )

        let result = RemoteContextInbox(rootURL: root.appendingPathComponent("inbox"))
            .receive(expired, assetURL: source)

        expect(!result.accepted, "rejects an expired context item")
        expect(
            result.message == "This context item expired before delivery.",
            "uses a safe fixed expiry message"
        )
    }

    private static func testRejectsEmptyAsset() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty")
        try? Data().write(to: source)

        let result = RemoteContextInbox(rootURL: root.appendingPathComponent("inbox"))
            .receive(makeTransfer(filename: "empty.txt"), assetURL: source)

        expect(!result.accepted, "rejects an empty asset before persisting it")
    }

    private static func testListsNewestItemsFirstAndIgnoresNoise() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = RemoteContextInbox(rootURL: root.appendingPathComponent("inbox"))
        let firstSource = root.appendingPathComponent("first.txt")
        let secondSource = root.appendingPathComponent("second.txt")
        try? Data("first".utf8).write(to: firstSource)
        try? Data("second".utf8).write(to: secondSource)

        let olderTransfer = makeTransfer(filename: "older.txt")
        let newerTransfer = makeTransfer(filename: "newer.txt")
        _ = inbox.receive(olderTransfer, assetURL: firstSource)
        _ = inbox.receive(newerTransfer, assetURL: secondSource)

        let olderFile = inbox.rootURL
            .appendingPathComponent(olderTransfer.id.uuidString, isDirectory: true)
            .appendingPathComponent("older.txt")
        let newerFile = inbox.rootURL
            .appendingPathComponent(newerTransfer.id.uuidString, isDirectory: true)
            .appendingPathComponent("newer.txt")
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        try? FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: olderFile.path)
        try? FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newerFile.path)

        let strayDirectory = inbox.rootURL.appendingPathComponent("not-a-transfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: strayDirectory, withIntermediateDirectories: true)
        let strayFile = inbox.rootURL.appendingPathComponent("README.txt")
        try? Data("ignore me".utf8).write(to: strayFile)

        let items = inbox.items(limit: 1)

        expect(items.count == 1, "applies the requested inbox item limit")
        expect(items.first?.transferID == newerTransfer.id, "sorts inbox items from newest to oldest")
        expect(items.first?.filename == "newer.txt", "returns the delivered payload filename")
    }

    private static func testPlacesAnExplicitCopyWithoutOverwriting() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.txt")
        let payload = Data("phone-provided context".utf8)
        try? payload.write(to: source)
        let inbox = RemoteContextInbox(rootURL: root.appendingPathComponent("inbox"))
        let transfer = makeTransfer(filename: "reference.txt")
        _ = inbox.receive(transfer, assetURL: source)
        guard let item = inbox.items().first else {
            fatalError("Test failed: received item should be listed")
        }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let original = project.appendingPathComponent("reference.txt")
        try? Data("existing project file".utf8).write(to: original)

        guard let destination = try? inbox.place(item, in: project) else {
            fatalError("Test failed: selected project folder should receive a copy")
        }
        expect(destination.lastPathComponent == "reference 2.txt", "does not overwrite an existing project file")
        expect((try? Data(contentsOf: destination)) == payload, "places an exact local copy")
        expect((try? Data(contentsOf: original)) == Data("existing project file".utf8), "leaves project files untouched")
        expect(FileManager.default.fileExists(atPath: item.fileURL.path), "retains the private inbox original")
    }

    private static func makeTransfer(
        filename: String,
        expiresAt: Date = Date().addingTimeInterval(60)
    ) -> CompanionContextTransfer {
        CompanionContextTransfer(
            id: UUID(),
            targetDeviceID: "test-mac",
            requesterDeviceID: "test-phone",
            filename: filename,
            typeIdentifier: "public.data",
            byteCount: 15,
            createdAt: Date(),
            expiresAt: expiresAt
        )
    }

    private static func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteContextInboxTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}
