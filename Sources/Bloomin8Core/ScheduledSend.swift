import Foundation

/// A day of the week, using Foundation's own `Calendar` weekday numbering
/// (1 = Sunday ... 7 = Saturday) so schedule checks need no conversion —
/// `Calendar.current.component(.weekday, from:)` can be compared to this
/// directly.
public enum Weekday: Int, CaseIterable, Codable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var id: Int { rawValue }

    public var shortLabel: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    /// Mon..Sun for display — Calendar's own numbering starts the week on
    /// Sunday, which reads oddly in a day-picker UI.
    public static let displayOrder: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
}

/// One photo scheduled to be sent to the frame at a fixed time on chosen
/// days — e.g. a "safe" photo that reverts the display at the end of the
/// day. `devicePath` points at a photo already uploaded to a gallery on the
/// frame (the same `/gallerys/<gallery>/<file>` path `LibraryItem` and
/// `PhotoController.showImageAtPath` use) rather than a file on this Mac —
/// firing the schedule just re-displays it, no upload involved.
public struct ScheduledSend: Codable, Equatable {
    public var isEnabled: Bool
    public var devicePath: String
    /// Minutes since midnight, local time — same convention as
    /// `AppSettings.autoRandomDailyMinute`.
    public var timeMinutes: Int
    public var days: Set<Weekday>
    /// Only actually send if the image currently on the frame belongs to a
    /// locked gallery tab or a Local Folder/Favorites-sourced photo while
    /// that lock is on — lets this act as a "revert to a safe photo" safety
    /// net instead of firing regardless of what's already showing.
    public var requireHiddenGalleryDisplayed: Bool

    public init(
        isEnabled: Bool = true,
        devicePath: String = "",
        timeMinutes: Int = 17 * 60,
        days: Set<Weekday> = Set(Weekday.allCases),
        requireHiddenGalleryDisplayed: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.devicePath = devicePath
        self.timeMinutes = timeMinutes
        self.days = days
        self.requireHiddenGalleryDisplayed = requireHiddenGalleryDisplayed
    }
}
