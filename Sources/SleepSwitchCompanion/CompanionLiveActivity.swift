import ActivityKit
import Foundation

@MainActor
final class CompanionLiveActivityController {
    func synchronize(with mac: CompanionMacStatus?) {
        guard #available(iOS 16.2, *) else { return }
        Task {
            let activities = Activity<ManualSessionActivityAttributes>.activities
            guard let mac, let session = mac.manualSession, session.isActive else {
                for activity in activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                return
            }

            let state = ManualSessionActivityAttributes.ContentState(
                macName: mac.displayName,
                endsAt: session.endsAt,
                isIndefinite: session.endsAt == nil,
                updatedAt: Date()
            )
            let content = ActivityContent(state: state, staleDate: session.endsAt)
            if let activity = activities.first {
                await activity.update(content)
            } else {
                do {
                    _ = try Activity.request(
                        attributes: ManualSessionActivityAttributes(macName: mac.displayName),
                        content: content,
                        pushType: nil
                    )
                } catch {
                    // Live Activities are optional and can be disabled by the user.
                }
            }
        }
    }
}
