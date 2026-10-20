import Foundation

/// A generated picture (NASA Photo of the Day, Fortune, Moon Phase, …) shown
/// on the frame automatically at a fixed time on chosen days — e.g. today's
/// NASA picture every morning. Unlike `ScheduledSend`, which re-displays a
/// photo already on the frame, this makes a fresh one each time it fires.
public struct ScheduledContent: Codable, Equatable {
    /// Not a `ContentSource`: a photo from the user's Photos library taken on
    /// this day in an earlier year. Handled by the windowed app, which owns
    /// the Photos access.
    public static let onThisDayPhotosSourceID = "photos.onThisDay"

    public var isEnabled: Bool
    /// `ContentSource.id` — see `ContentSources.all`.
    public var sourceID: String
    /// Minutes since midnight, local time — same convention as
    /// `ScheduledSend.timeMinutes`.
    public var timeMinutes: Int
    public var days: Set<Weekday>
    /// For a source that has a "today" item (`TodayContentSource` — NASA's
    /// actual picture of the day), show that rather than a random one.
    public var useToday: Bool

    public init(
        isEnabled: Bool = true,
        sourceID: String = "apod",
        timeMinutes: Int = 7 * 60,
        days: Set<Weekday> = Set(Weekday.allCases),
        useToday: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.sourceID = sourceID
        self.timeMinutes = timeMinutes
        self.days = days
        self.useToday = useToday
    }
}
