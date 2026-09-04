import Foundation

enum RemoteContextInboxTests {
    static func run() {
        testReceivesOneSafeCopy()
        testRejectsExpiredTransfer()
        testRejectsEmptyAsset()
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
