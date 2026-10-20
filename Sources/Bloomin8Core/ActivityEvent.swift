import Foundation

/// One entry in `PhotoController.recentActivity` — a record of something the
/// app tried to do to the frame (upload, show, delete, device settings,
/// scheduled send, keep awake), kept so a failure that only flashed briefly
/// in `statusText` is still findable afterwards. In-memory only: this is a
/// diagnostic trail for "what just happened", not something that needs to
/// survive a relaunch.
public struct ActivityEvent: Identifiable, Equatable {
    public let id = UUID()
    public let date: Date
    public let message: String
    public let success: Bool

    public init(date: Date = Date(), message: String, success: Bool) {
        self.date = date
        self.message = message
        self.success = success
    }
}

extension PhotoController {
    /// Most-recent-first activity log, capped so it never grows unbounded
    /// across a long-running session.
    static let activityLogLimit = 50

    /// Appends an outcome to `recentActivity`, trimming to the cap and, on
    /// failure, raising `hasUnseenActivityFailure` for the toolbar badge.
    public func logActivity(_ message: String, success: Bool) {
        recentActivity.insert(ActivityEvent(message: message, success: success), at: 0)
        if recentActivity.count > Self.activityLogLimit {
            recentActivity.removeLast(recentActivity.count - Self.activityLogLimit)
        }
        if !success {
            hasUnseenActivityFailure = true
        }
    }
}
