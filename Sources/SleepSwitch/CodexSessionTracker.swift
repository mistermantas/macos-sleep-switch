import Foundation

struct CodexSessionTracker {
    private static let taskStartedMarker = "\"type\":\"task_started\""
    private static let taskCompleteMarker = "\"type\":\"task_complete\""

    let sessionsDirectory: URL
    let activeFileWindow: TimeInterval
    let tailByteCount: Int
    let now: () -> Date

    init(
        sessionsDirectory: URL = CodexSessionTracker.defaultSessionsDirectory,
        activeFileWindow: TimeInterval = 12 * 60 * 60,
        tailByteCount: Int = 512 * 1024,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.activeFileWindow = activeFileWindow
        self.tailByteCount = tailByteCount
        self.now = now
    }

    func scan() -> Int? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sessionsDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        let cutoff = now().addingTimeInterval(-activeFileWindow)
        var activeCount = 0

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else {
                continue
            }

            if isTaskActive(in: fileURL) {
                activeCount += 1
            }
        }

        return activeCount
    }

    private func isTaskActive(in fileURL: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return false
        }
        defer {
            try? fileHandle.close()
        }

        guard let fileSize = try? fileHandle.seekToEnd() else {
            return false
        }

        let tailSize = min(UInt64(tailByteCount), fileSize)
        guard (try? fileHandle.seek(toOffset: fileSize - tailSize)) != nil,
              let tailData = try? fileHandle.read(upToCount: Int(tailSize)) else {
            return false
        }

        let tail = String(decoding: tailData, as: UTF8.self)
        let lastStarted = tail.range(
            of: Self.taskStartedMarker,
            options: .backwards
        )?.lowerBound
        let lastCompleted = tail.range(
            of: Self.taskCompleteMarker,
            options: .backwards
        )?.lowerBound

        switch (lastStarted, lastCompleted) {
        case (.some(let started), .some(let completed)):
            return started > completed
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            // Active turns can write far more than the tail window after their
            // task_started event. Completed turns end with task_complete, so a
            // large recent file without either marker is still in progress.
            return fileSize > tailSize
        }
    }

    private static var defaultSessionsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)

        return codexHome.appendingPathComponent("sessions", isDirectory: true)
    }
}
