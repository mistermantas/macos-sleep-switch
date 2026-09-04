import Foundation

enum CompanionContextTransferActivityState: String, Codable, Equatable {
    case sending
    case waitingForMac
    case delivered
    case rejected
    case pending
    case failed

    var title: String {
        switch self {
        case .sending: "Sending"
        case .waitingForMac: "Waiting"
        case .delivered: "Delivered"
        case .rejected: "Rejected"
        case .pending: "Pending"
        case .failed: "Failed"
        }
    }
}

struct CompanionContextTransferActivity: Codable, Equatable, Identifiable {
    let transferID: UUID
    let targetDeviceID: String
    let targetDisplayName: String
    let filename: String
    let byteCount: Int64
    let updatedAt: Date
    let state: CompanionContextTransferActivityState

    var id: UUID { transferID }
}

final class CompanionContextTransferHistoryStore {
    static let storageKey = "companionContextTransferHistory"
    static let maximumItems = 24

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumItems: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = storageKey,
        maximumItems: Int = maximumItems
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumItems = maximumItems
    }

    var items: [CompanionContextTransferActivity] {
        guard let data = defaults.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([CompanionContextTransferActivity].self, from: data) else {
            return []
        }
        return items.sorted(by: newestFirst)
    }

    @discardableResult
    func record(_ item: CompanionContextTransferActivity) -> [CompanionContextTransferActivity] {
        var stored = items.filter { $0.transferID != item.transferID }
        stored.insert(item, at: 0)
        stored.sort(by: newestFirst)
        if stored.count > maximumItems {
            stored.removeSubrange(maximumItems..<stored.count)
        }
        persist(stored)
        return stored
    }

    func recentItems(for deviceID: String, limit: Int = 3) -> [CompanionContextTransferActivity] {
        items
            .filter { $0.targetDeviceID == deviceID }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private func persist(_ items: [CompanionContextTransferActivity]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func newestFirst(
        _ left: CompanionContextTransferActivity,
        _ right: CompanionContextTransferActivity
    ) -> Bool {
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.filename.localizedCaseInsensitiveCompare(right.filename) == .orderedAscending
    }
}
