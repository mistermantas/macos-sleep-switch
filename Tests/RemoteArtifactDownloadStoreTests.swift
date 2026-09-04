import Foundation

enum RemoteArtifactDownloadStoreTests {
    static func run() throws {
        try storesOnlyTheOfferedFile()
        try rejectsUnexpectedOrUnsafeFiles()
    }

    private static func storesOnlyTheOfferedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteArtifactDownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = Data("private result".utf8)
        try contents.write(to: source)
        let offer = makeOffer(filename: "summary.pdf", byteCount: Int64(contents.count))
        let store = RemoteArtifactDownloadStore(rootURL: root.appendingPathComponent("results", isDirectory: true))

        let destination = try store.store(assetAt: source, for: offer)
        let copiedContents = try Data(contentsOf: destination)

        expect(destination.lastPathComponent == "summary.pdf", "uses offered filename")
        expect(copiedContents == contents, "copies exact asset")
        expect(store.existingFile(for: offer) == destination, "finds retained explicit download")
    }

    private static func rejectsUnexpectedOrUnsafeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteArtifactDownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("abc".utf8).write(to: source)
        let store = RemoteArtifactDownloadStore(rootURL: root.appendingPathComponent("results", isDirectory: true))

        do {
            _ = try store.store(assetAt: source, for: makeOffer(filename: "../escape.txt", byteCount: 3))
            fatalError("Test failed: unsafe filename should fail")
        } catch let error as RemoteArtifactDownloadStore.StoreError {
            expect(error == .invalidMetadata, "rejects traversal filename")
        }

        do {
            _ = try store.store(assetAt: source, for: makeOffer(filename: "result.txt", byteCount: 2))
            fatalError("Test failed: unexpected size should fail")
        } catch let error as RemoteArtifactDownloadStore.StoreError {
            expect(error == .unexpectedSize, "rejects size mismatch")
        }
    }

    private static func makeOffer(filename: String, byteCount: Int64) -> CompanionArtifactOffer {
        CompanionArtifactOffer(
            id: UUID(),
            sourceDeviceID: "mac",
            filename: filename,
            typeIdentifier: nil,
            byteCount: byteCount,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}
