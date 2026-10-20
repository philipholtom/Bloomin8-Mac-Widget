import Foundation

/// Everything about ONE physical frame — its address, how it's mounted,
/// which galleries/tabs it shows, and its own schedules. Everything else on
/// `AppSettings` (NASA API key, weather location, Local Folder path, Touch
/// ID preference, etc.) is about this Mac or this user, not any particular
/// frame, so it stays outside this struct and is shared across every
/// profile.
///
/// `einkshotToken` is deliberately NOT a field here — like `GalleryTab`'s
/// `passwordHash`, it's a secret and lives in the secret store (`SecretStore`) instead, keyed by
/// this profile's `id` (see `AppSettings.einkshotToken`).
public struct FrameProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var deviceIP: String
    public var bleDeviceName: String
    /// The frame's native panel resolution as last reported by
    /// `/deviceInfo` — see `AppSettings.renderWidth`/`renderHeight` for why
    /// this isn't itself orientation-aware.
    public var frameWidth: Int
    public var frameHeight: Int
    public var frameOrientation: FrameOrientation
    public var selectedGalleries: Set<String>
    public var tabs: [GalleryTab]
    public var autoRandomEnabled: Bool
    public var autoRandomInterval: AutoRandomInterval
    public var autoRandomDailyMinute: Int
    public var selectedContentSources: Set<String>
    public var cropLandscapePhotos: Bool
    public var favoriteImagePaths: [String]
    public var scheduledSend: ScheduledSend?
    public var scheduledContent: ScheduledContent?
    public var photosMirror: PhotosMirror?

    public init(name: String = "New Frame") {
        self.id = UUID()
        self.name = name
        self.deviceIP = ""
        self.bleDeviceName = "Office"
        self.frameWidth = 1200
        self.frameHeight = 1600
        self.frameOrientation = .portrait
        self.selectedGalleries = []
        self.tabs = []
        self.autoRandomEnabled = false
        self.autoRandomInterval = .hourly
        self.autoRandomDailyMinute = 9 * 60
        self.selectedContentSources = []
        self.cropLandscapePhotos = false
        self.favoriteImagePaths = []
        self.scheduledSend = nil
        self.scheduledContent = nil
        self.photosMirror = nil
    }
}
