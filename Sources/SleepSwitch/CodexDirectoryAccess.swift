import AppKit
import Foundation

final class CodexDirectoryAccess {
    private let bookmarkKey = "codexDirectoryBookmark"
    private let lock = NSLock()
    private var grantedDirectory: URL?
    private var isAccessingGrantedDirectory = false

    var isConnected: Bool {
        lock.withLock { grantedDirectory != nil }
    }

    var sessionsDirectory: URL? {
        lock.withLock {
            grantedDirectory.map(Self.sessionsDirectory(for:))
        }
    }

    func restoreAccess() {
#if APP_STORE
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return
        }

        var isStale = false
        guard let directory = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }

        setGrantedDirectory(directory)
        if isStale {
            persistBookmark(for: directory)
        }
#endif
    }

    @MainActor
    func requestAccess() -> Bool {
#if APP_STORE
        let panel = NSOpenPanel()
        panel.title = "Connect Codex"
        panel.message = "Choose your .codex folder so Sleep Switch can watch active tasks."
        panel.prompt = "Connect"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = ".codex"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else {
            return false
        }

        setGrantedDirectory(directory)
        persistBookmark(for: directory)
        return true
#else
        return false
#endif
    }

    func disconnect() {
#if APP_STORE
        lock.withLock {
            if isAccessingGrantedDirectory {
                grantedDirectory?.stopAccessingSecurityScopedResource()
            }
            grantedDirectory = nil
            isAccessingGrantedDirectory = false
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
#endif
    }

    private func setGrantedDirectory(_ directory: URL) {
        lock.withLock {
            if isAccessingGrantedDirectory {
                grantedDirectory?.stopAccessingSecurityScopedResource()
            }

            grantedDirectory = directory
            isAccessingGrantedDirectory = directory.startAccessingSecurityScopedResource()
        }
    }

    private func persistBookmark(for directory: URL) {
        guard let bookmark = try? directory.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private static func sessionsDirectory(for grantedDirectory: URL) -> URL {
        if grantedDirectory.lastPathComponent == "sessions" {
            return grantedDirectory
        }

        return grantedDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    deinit {
        lock.withLock {
            if isAccessingGrantedDirectory {
                grantedDirectory?.stopAccessingSecurityScopedResource()
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
