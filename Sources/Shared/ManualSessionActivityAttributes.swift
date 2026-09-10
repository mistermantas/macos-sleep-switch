import ActivityKit
import Foundation

struct ManualSessionActivityAttributes: ActivityAttributes {
    typealias ContentState = CompanionLiveActivityContentState

    var macName: String
    var deviceID: String? = nil
    var origin: CompanionLiveActivityOrigin? = nil
    var startedAt: Date? = nil
    var automaticTriggerID: String? = nil
}
