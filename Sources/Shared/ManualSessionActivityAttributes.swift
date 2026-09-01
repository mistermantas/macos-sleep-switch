import ActivityKit
import Foundation

struct ManualSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var macName: String
        var endsAt: Date?
        var isIndefinite: Bool
        var updatedAt: Date
    }

    var macName: String
}
