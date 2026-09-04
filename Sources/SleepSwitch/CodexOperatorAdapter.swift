import Foundation

/// Reads Codex rollout logs as a one-way, whitelisted transform. It never
/// stores a JSON line or exposes prompts/tool messages to Operator.
struct CodexOperatorAdapter: OperatorAdapter {
    let harnessID = "codex"
    let harnessName = "Codex"
    let sessionsDirectory: URL
    let now: () -> Date
    let maximumFiles: Int
    let activeFileWindow: TimeInterval
    let tailByteCount: Int

    init(
        sessionsDirectory: URL,
        maximumFiles: Int = 24,
        activeFileWindow: TimeInterval = 15 * 60,
        tailByteCount: Int = 512 * 1024,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.maximumFiles = max(1, maximumFiles)
        self.activeFileWindow = max(60, activeFileWindow)
        self.tailByteCount = max(64 * 1024, tailByteCount)
        self.now = now
    }

    func snapshot() -> OperatorAdapterSnapshot {
        let refreshedAt = now()
        let capabilities = [
            HarnessCapability(harnessID: harnessID, kind: .sessions, isSupported: true),
            HarnessCapability(harnessID: harnessID, kind: .sessionHistory, isSupported: true),
            HarnessCapability(harnessID: harnessID, kind: .tokenUsage, isSupported: true)
        ]
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: sessionsDirectory.path,
            isDirectory: &directory
        ), directory.boolValue else {
            return OperatorAdapterSnapshot(
                harnessID: harnessID,
                harnessName: harnessName,
                availability: .permissionRequired,
                refreshedAt: refreshedAt,
                capabilities: capabilities,
                sessions: [],
                events: []
            )
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return unavailableSnapshot(refreshedAt: refreshedAt, capabilities: capabilities)
        }

        let cutoff = refreshedAt.addingTimeInterval(-activeFileWindow)
        let files = enumerator.compactMap { item -> (url: URL, modifiedAt: Date)? in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else {
                return nil
            }
            return (url, modifiedAt)
        }
        .sorted {
            $0.modifiedAt > $1.modifiedAt
        }
        .prefix(maximumFiles)

        var sessions: [OperatorSession] = []
        var events: [OperatorEvent] = []
        var malformedCount = 0
        for file in files {
            switch parseSession(at: file.url, fallbackDate: file.modifiedAt) {
            case .success(let parsed):
                sessions.append(parsed.session)
                events.append(contentsOf: parsed.events)
            case .failure:
                malformedCount += 1
            }
        }

        return OperatorAdapterSnapshot(
            harnessID: harnessID,
            harnessName: harnessName,
            availability: sessions.isEmpty && malformedCount > 0 ? .malformedSource : .available,
            refreshedAt: refreshedAt,
            capabilities: capabilities,
            sessions: sessions.sorted { $0.startedAt > $1.startedAt },
            events: events.sorted { $0.occurredAt > $1.occurredAt }
        )
    }

    private func unavailableSnapshot(
        refreshedAt: Date,
        capabilities: [HarnessCapability]
    ) -> OperatorAdapterSnapshot {
        OperatorAdapterSnapshot(
            harnessID: harnessID,
            harnessName: harnessName,
            availability: .unavailable,
            refreshedAt: refreshedAt,
            capabilities: capabilities,
            sessions: [],
            events: []
        )
    }

    private func parseSession(
        at url: URL,
        fallbackDate: Date
    ) -> Result<(session: OperatorSession, events: [OperatorEvent]), Error> {
        guard let data = tailData(at: url) else {
            return .failure(CocoaError(.fileReadUnknown))
        }
        let sessionID = url.deletingPathExtension().lastPathComponent
        var startedAt: Date?
        var endedAt: Date?
        var lastActivityAt: Date?
        // Files arrive here only if they changed within the active window. A
        // current task can emit enough events to push task_started out of the
        // tail, so lack of a terminal marker means it is still live.
        var state: OperatorSessionState = .running
        var tokenTotal = 0

        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any] else {
                continue
            }
            let timestamp = parseDate(record["timestamp"]) ?? fallbackDate
            lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
            let eventType = ((record["payload"] as? [String: Any])?["type"] as? String)
                ?? (record["type"] as? String)
            switch eventType {
            case "task_started":
                startedAt = min(startedAt ?? timestamp, timestamp)
                state = .running
            case "task_complete":
                endedAt = max(endedAt ?? timestamp, timestamp)
                state = .finished
            case "turn_aborted":
                endedAt = max(endedAt ?? timestamp, timestamp)
                state = .aborted
            default:
                break
            }
            tokenTotal = max(tokenTotal, tokenValue(in: record))
        }

        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? fallbackDate
        let start = startedAt ?? fileDate
        let session = OperatorSession(
            id: sessionID,
            harnessID: harnessID,
            harnessName: harnessName,
            state: state,
            startedAt: start,
            endedAt: endedAt,
            lastActivityAt: lastActivityAt ?? fileDate,
            inputTokens: tokenTotal,
            outputTokens: 0,
            reasoningTokens: 0,
            cachedTokens: 0
        )
        let events = [
            OperatorEvent(
                id: "\(sessionID):started",
                sessionID: sessionID,
                harnessID: harnessID,
                kind: .sessionStarted,
                occurredAt: start
            )
        ] + (endedAt.map { end in
            [OperatorEvent(
                id: "\(sessionID):terminal",
                sessionID: sessionID,
                harnessID: harnessID,
                kind: state == .aborted ? .sessionAborted : .sessionFinished,
                occurredAt: end
            )]
        } ?? [])
        return .success((session, events))
    }

    private func tokenValue(in value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            let direct = ["tokens_used", "total_tokens"].compactMap { key -> Int? in
                guard let number = dictionary[key] as? NSNumber else { return nil }
                return max(0, number.intValue)
            }.max() ?? 0
            return max(direct, dictionary.values.map(tokenValue(in:)).max() ?? 0)
        }
        if let values = value as? [Any] {
            return values.map(tokenValue(in:)).max() ?? 0
        }
        return 0
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = value as? String {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }

    private func tailData(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(UInt64(tailByteCount), size)
        guard (try? handle.seek(toOffset: size - count)) != nil else { return nil }
        return try? handle.read(upToCount: Int(count))
    }
}
