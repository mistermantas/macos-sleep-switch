import Foundation

/// A small, private App Group staging area used by the iOS Share extension and
/// the companion app. Staging is not delivery: the companion still asks the
/// user to choose a paired Mac and explicitly send the item.
struct SharedContextDraft: Codable, Equatable, Identifiable {
    let id: UUID
    let filename: String
    let byteCount: Int64
    let receivedAt: Date
    let expiresAt: Date
}

enum SharedContextIntakeError: LocalizedError, Equatable {
    case unavailable
    case folderNotSupported
    case fileTooLarge
    case sourceUnavailable
    case linkNotSupported
    case stagingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Shared context is unavailable on this device."
        case .folderNotSupported: "Share one file at a time, not a folder."
        case .fileTooLarge: "Shared context is limited to 25 MB."
        case .sourceUnavailable: "That shared item is no longer available."
        case .linkNotSupported: "Share a standard http or https link."
        case .stagingFailed: "Sleep Switch could not safely stage that item."
        }
    }
}

/// This intentionally supports only one bounded file per draft. It is a
/// private handoff receipt, never a browsable shared filesystem.
struct SharedContextIntake {
    static let appGroupIdentifier = "group.lt.mantas.sleepswitch"
    static let maximumBytes: Int64 = 25 * 1024 * 1024
    static let lifetime: TimeInterval = 24 * 60 * 60

    let rootURL: URL?

    init(fileManager: FileManager = .default) {
        rootURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent("Shared Context", isDirectory: true)
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func drafts(fileManager: FileManager = .default, now: Date = Date()) -> [SharedContextDraft] {
        guard let rootURL else { return [] }
        pruneExpired(fileManager: fileManager, now: now)
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: manifestURL(for: directory)),
                  let draft = try? JSONDecoder().decode(SharedContextDraft.self, from: data),
                  draft.id == id,
                  draft.expiresAt > now,
                  let fileURL = fileURL(for: draft),
                  fileURL.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                    directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                  ),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == draft.byteCount
            else {
                return nil
            }
            return draft
        }
        .sorted { $0.receivedAt > $1.receivedAt }
    }

    func fileURL(for draft: SharedContextDraft) -> URL? {
        guard let rootURL else { return nil }
        return rootURL
            .appendingPathComponent(draft.id.uuidString, isDirectory: true)
            .appendingPathComponent(safeFilename(draft.filename), isDirectory: false)
    }

    func stage(
        fileAt sourceURL: URL,
        suggestedFilename: String? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> SharedContextDraft {
        guard let rootURL else { throw SharedContextIntakeError.unavailable }
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw SharedContextIntakeError.sourceUnavailable
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw SharedContextIntakeError.folderNotSupported }
        let byteCount = Int64(values.fileSize ?? -1)
        guard (0...Self.maximumBytes).contains(byteCount) else {
            throw SharedContextIntakeError.fileTooLarge
        }

        let draft = SharedContextDraft(
            id: UUID(),
            filename: safeFilename(suggestedFilename ?? source.lastPathComponent),
            byteCount: byteCount,
            receivedAt: now,
            expiresAt: now.addingTimeInterval(Self.lifetime)
        )
        let directory = rootURL.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(draft.filename, isDirectory: false)
        let temporary = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            let manifest = try JSONEncoder().encode(draft)
            try manifest.write(to: manifestURL(for: directory), options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL(for: directory).path)
            return draft
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SharedContextIntakeError.stagingFailed
        }
    }

    /// Stores a link as a small local `.url` context item. It intentionally
    /// does not fetch the page or contact a network service from the extension.
    func stage(
        url: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> SharedContextDraft {
        guard let rootURL else { throw SharedContextIntakeError.unavailable }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw SharedContextIntakeError.linkNotSupported
        }
        let data = Data(url.absoluteString.utf8)
        guard Int64(data.count) <= Self.maximumBytes else {
            throw SharedContextIntakeError.fileTooLarge
        }

        let host = safeFilename(url.host ?? "shared-link")
        let draft = SharedContextDraft(
            id: UUID(),
            filename: safeFilename("\(host).url"),
            byteCount: Int64(data.count),
            receivedAt: now,
            expiresAt: now.addingTimeInterval(Self.lifetime)
        )
        let directory = rootURL.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(draft.filename, isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: destination, options: [.atomic])
            try JSONEncoder().encode(draft).write(to: manifestURL(for: directory), options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL(for: directory).path)
            return draft
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SharedContextIntakeError.stagingFailed
        }
    }

    func discard(_ draft: SharedContextDraft, fileManager: FileManager = .default) {
        guard let rootURL else { return }
        let directory = rootURL.appendingPathComponent(draft.id.uuidString, isDirectory: true)
        try? fileManager.removeItem(at: directory)
    }

    func pruneExpired(fileManager: FileManager = .default, now: Date = Date()) {
        guard let rootURL,
              let directories = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return }
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            guard let data = try? Data(contentsOf: manifestURL(for: directory)),
                  let draft = try? JSONDecoder().decode(SharedContextDraft.self, from: data),
                  draft.expiresAt > now
            else {
                try? fileManager.removeItem(at: directory)
                continue
            }
        }
    }

    private func manifestURL(for directory: URL) -> URL {
        directory.appendingPathComponent("draft.json", isDirectory: false)
    }

    private func safeFilename(_ proposed: String) -> String {
        let raw = URL(fileURLWithPath: proposed).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let name = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "shared-context" : String(name.prefix(160))
    }
}
