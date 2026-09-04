import Foundation

/// Finds skill files without changing them. The file body is only read to
/// derive a local fingerprint/name and is immediately discarded.
struct OperatorSkillIndexer {
    struct Source: Equatable {
        let url: URL
        let label: String
    }

    let sources: [Source]
    let maximumFileBytes: Int

    init(sources: [Source], maximumFileBytes: Int = 128 * 1024) {
        self.sources = sources
        self.maximumFileBytes = max(1_024, maximumFileBytes)
    }

    func index() -> [OperatorSkill] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        return sources.flatMap { source -> [OperatorSkill] in
            guard let enumerator = FileManager.default.enumerator(
                at: source.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      url.lastPathComponent == "SKILL.md",
                      (try? url.resourceValues(forKeys: keys).isRegularFile) == true,
                      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                    return nil
                }
                let clipped = data.prefix(maximumFileBytes)
                let modifiedAt = (try? url.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return OperatorSkill(
                    id: "skill:\(stableHash(url.path))",
                    sourceURL: url,
                    name: name(from: clipped) ?? url.deletingLastPathComponent().lastPathComponent,
                    sourceGroup: source.label,
                    fingerprint: stableHash(Data(clipped)),
                    modifiedAt: modifiedAt
                )
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func name(from data: Data) -> String? {
        let prefix = String(decoding: data.prefix(8 * 1024), as: UTF8.self)
        for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'")) }
            }
            if trimmed.hasPrefix("# ") {
                let value = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private func stableHash(_ value: String) -> String {
        stableHash(Data(value.utf8))
    }

    private func stableHash(_ data: Data) -> String {
        data.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        .description
    }
}
