import Foundation

/// A generator that produces a fresh 1200x1600 JPEG to push to the frame,
/// as opposed to picking an existing photo from an on-device gallery.
public protocol ContentSource {
    var id: String { get }
    var displayName: String { get }
    /// The on-device gallery this source's images are uploaded into —
    /// matches the galleries the original Python scripts already used
    /// (e.g. "NASA" for APOD), so generated content lands alongside
    /// whatever they already uploaded there rather than a new catch-all.
    var galleryName: String { get }
    func generateImage(settings: AppSettings) async throws -> Data
    /// The same picture together with a museum card describing it (what it
    /// is, when, who made it), for sources that know. Sources that don't just
    /// get the default, which returns the picture with no card.
    func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent
}

extension ContentSource {
    public func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        GeneratedContent(data: try await generateImage(settings: settings), card: nil)
    }
}

/// A generated picture, and the museum card that describes it if the source
/// has one to offer.
public struct GeneratedContent {
    public var data: Data
    public var card: MuseumCard?

    public init(data: Data, card: MuseumCard? = nil) {
        self.data = data
        self.card = card
    }
}

/// A source that can also produce "today's" item, not only a random one — for
/// APOD, the actual picture of the day. The picker offers it as a button, and
/// scheduled auto-show uses it instead of a random date.
public protocol TodayContentSource: ContentSource {
    var todayButtonTitle: String { get }
    func generateTodayImage(settings: AppSettings) async throws -> Data
    func generateTodayImageAndCard(settings: AppSettings) async throws -> GeneratedContent
}

extension TodayContentSource {
    public func generateTodayImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        GeneratedContent(data: try await generateTodayImage(settings: settings), card: nil)
    }
}

public enum ContentSourceError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Wikimedia's API etiquette requires a descriptive User-Agent — the
/// original Python scripts embedded a personal name/email, which doesn't
/// belong in a public repo, so this identifies the app instead.
public let contentSourceUserAgent = "Bloomin8Widget/1.0 (+https://github.com/philipholtom/Bloomin8-Mac-Widget)"

public enum ContentSources {
    public static let all: [ContentSource] = [
        APODSource(),
        FortuneSource(),
        WeatherSource(),
        MoonPhaseSource(),
        HistorySource(),
        PeriodicTableSource(),
        MarsRoverSource(),
        EPICSource(),
        MuseumArtSource(),
        WikipediaPOTDSource(),
        CatPhotoSource(),
        DogPhotoSource(),
        SatelliteMapSource()
    ]
}
