import Foundation

/// Stores an artifact only after the companion user explicitly chooses to get
/// it. Files never become a browsable mirror of the Mac: each directory is
/// keyed to one short-lived, Mac-authored offer.
final class RemoteArtifactDownloadStore {
    enum StoreError: LocalizedError, Equatable {
        case expired
        case invalidMetadata
        case assetUnavailable
        case unexpectedSize

        var errorDescription: String? {
            switch self {
            case .expired:
                "This result is no longer available."
            case .invalidMetadata:
                "This result could not be stored safely."
            case .assetUnavailable:
                "This result is no longer available on iCloud."
            case .unexpectedSize:
                "The received result did not match the Mac’s offer."
            }
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Sleep Switch", isDirectory: true)
        .appendingPathComponent("Received Results", isDirectory: true)
    }

    func existingFile(for offer: CompanionArtifactOffer) -> URL? {
        guard let filename = safeFilename(offer.filename) else { return nil }
        let url = directory(for: offer)
            .appendingPathComponent(filename, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func store(assetAt sourceURL: URL?, for offer: CompanionArtifactOffer) throws -> URL {
        guard !offer.isExpired else { throw StoreError.expired }
        guard CompanionArtifactOfferPolicy.isAllowed(byteCount: offer.byteCount),
              let filename = safeFilename(offer.filename)
        else {
            throw StoreError.invalidMetadata
        }
        guard let sourceURL else { throw StoreError.assetUnavailable }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw StoreError.assetUnavailable
        }
        guard Int64(size) == offer.byteCount else { throw StoreError.unexpectedSize }

        let destinationDirectory = directory(for: offer)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destinationURL = destinationDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destinationURL.path
        )
        return destinationURL
    }

    private func directory(for offer: CompanionArtifactOffer) -> URL {
        rootURL.appendingPathComponent(offer.id.uuidString, isDirectory: true)
    }

    private func safeFilename(_ filename: String) -> String? {
        let candidate = URL(fileURLWithPath: filename).lastPathComponent
        guard candidate == filename,
              !candidate.isEmpty,
              candidate != ".",
              candidate != ".."
        else {
            return nil
        }
        return candidate
    }
}
