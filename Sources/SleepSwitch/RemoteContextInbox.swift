import Foundation

struct RemoteContextInboxItem: Identifiable, Equatable {
    let transferID: UUID
    let fileURL: URL
    let filename: String
    let byteCount: Int64
    let receivedAt: Date

    var id: UUID { transferID }
}

/// A private holding area for items the companion explicitly sends to this
/// Mac. The receiver never chooses a repository, invokes an agent, or opens
/// the file. Those are separate, visible user decisions made after delivery.
struct RemoteContextInbox {
    enum PlacementError: LocalizedError, Equatable {
        case sourceUnavailable
        case invalidDestination
        case placementFailed

        var errorDescription: String? {
            switch self {
            case .sourceUnavailable:
                "This Remote Inbox item is no longer available."
            case .invalidDestination:
                "Choose a folder where Sleep Switch can place the item."
            case .placementFailed:
                "Sleep Switch could not copy the item to that folder."
            }
        }
    }

    let rootURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        rootURL = support
            .appendingPathComponent("Sleep Switch", isDirectory: true)
            .appendingPathComponent("Remote Inbox", isDirectory: true)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Lists exactly one completed payload per transfer directory. This is a
    /// receipt surface, not a general filesystem browser.
    func items(
        limit: Int = 24,
        fileManager: FileManager = .default
    ) -> [RemoteContextInboxItem] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories.compactMap { directory in
            guard let transferID = UUID(uuidString: directory.lastPathComponent),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                return nil
            }
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .creationDateKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ],
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let fileURL = files.first(where: {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }), let values = try? fileURL.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey
            ])
            else {
                return nil
            }
            return RemoteContextInboxItem(
                transferID: transferID,
                fileURL: fileURL,
                filename: fileURL.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0),
                receivedAt: values.contentModificationDate ?? values.creationDate ?? .distantPast
            )
        }
        .sorted {
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
            return $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    func receive(
        _ transfer: CompanionContextTransfer,
        assetURL: URL,
        fileManager: FileManager = .default
    ) -> CompanionContextTransferResult {
        let now = Date()
        guard transfer.expiresAt > now else {
            return rejected(transfer, at: now, message: "This context item expired before delivery.")
        }
        guard let fileSize = try? assetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              CompanionContextTransferPolicy.isAllowed(byteCount: Int64(fileSize)) else {
            return rejected(transfer, at: now, message: "This context item is outside Sleep Switch’s size limit.")
        }

        let directory = rootURL.appendingPathComponent(transfer.id.uuidString, isDirectory: true)
        let filename = safeFilename(transfer.filename)
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if fileManager.fileExists(atPath: destination.path) {
                return accepted(transfer, at: now, message: "Already received.")
            }
            let temporary = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
            try fileManager.copyItem(at: assetURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            return accepted(transfer, at: now, message: "Delivered to Remote Inbox.")
        } catch {
            return rejected(transfer, at: now, message: "Sleep Switch could not store this context item.")
        }
    }

    /// Copies an inbox item into a folder the Mac owner explicitly selected.
    /// This is intentionally a local file action only: it does not select an
    /// agent session, alter a prompt, or execute anything after placement.
    func place(
        _ item: RemoteContextInboxItem,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let source = item.fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard source.path.hasPrefix(root),
              fileManager.fileExists(atPath: source.path)
        else {
            throw PlacementError.sourceUnavailable
        }
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw PlacementError.invalidDestination
        }

        let destination = availableDestination(
            filename: safeFilename(item.filename),
            in: directory.standardizedFileURL,
            fileManager: fileManager
        )
        let temporary = directory.appendingPathComponent(".sleep-switch-placement-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw PlacementError.placementFailed
        }
    }

    private func availableDestination(
        filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let original = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for suffix in 2...999 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)", isDirectory: false)
    }

    private func accepted(
        _ transfer: CompanionContextTransfer,
        at date: Date,
        message: String
    ) -> CompanionContextTransferResult {
        CompanionContextTransferResult(
            transferID: transfer.id,
            accepted: true,
            deliveredAt: date,
            message: message
        )
    }

    private func rejected(
        _ transfer: CompanionContextTransfer,
        at date: Date,
        message: String
    ) -> CompanionContextTransferResult {
        CompanionContextTransferResult(
            transferID: transfer.id,
            accepted: false,
            deliveredAt: date,
            message: message
        )
    }

    private func safeFilename(_ proposed: String) -> String {
        let raw = URL(fileURLWithPath: proposed).lastPathComponent
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " ._-()[]"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "context-item" : cleaned
        return String(value.prefix(120))
    }
}
