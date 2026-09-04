import Foundation

/// The companion only interrupts for state transitions the Mac can prove.
/// This deliberately has no inactivity heuristic: a quiet session is not a
/// stalled one unless a harness supplies that evidence.
enum CompanionWorkAttentionKind: String, Codable, Equatable {
    case required
    case useful
}

enum CompanionWorkAttentionPolicy {
    static func kind(for state: CompanionWorkState) -> CompanionWorkAttentionKind? {
        switch state {
        case .stalled, .blocked, .rateLimited, .failed:
            .required
        case .finished, .reviewReady:
            .useful
        case .active, .waiting, .stopped, .unknown:
            nil
        }
    }
}
