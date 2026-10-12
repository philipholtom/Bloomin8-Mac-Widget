import CoreLocation
import Foundation
import ImageIO

/// The little museum-style label shown on the CrowPanel e-paper display next
/// to the frame: what the photo is, where and when it was taken. Keyed by the
/// photo's path on the frame (e.g. `/gallerys/Random/IMG_1234-ab12_P.jpg`),
/// since that's the only identifier the frame, the Mac and the CrowPanel all
/// share.
public struct MuseumCard: Codable, Equatable {
    public var title: String
    public var place: String
    public var date: String
    public var camera: String
    public var notes: String
    /// Set once the user has edited the card by hand, so a later automatic
    /// fill (sending the same photo again) doesn't overwrite their text.
    public var edited: Bool

    public init(title: String = "", place: String = "", date: String = "", camera: String = "", notes: String = "", edited: Bool = false) {
        self.title = title
        self.place = place
        self.date = date
        self.camera = camera
        self.notes = notes
        self.edited = edited
    }

    public var isEmpty: Bool {
        [title, place, date, camera, notes].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The card with HTML entities decoded ("&amp;" → "&") and stray
    /// whitespace trimmed in every text field — the display would show the
    /// raw "&amp;" otherwise.
    public func normalized() -> MuseumCard {
        func clean(_ text: String) -> String {
            TextCleaning.decodeHTMLEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var card = self
        card.title = clean(title)
        card.place = clean(place)
        card.date = clean(date)
        card.camera = clean(camera)
        card.notes = clean(notes)
        return card
    }
}

/// Every card, persisted as one JSON file in Application Support so the
/// widget and the app (and the card server, whichever of them is running it)
/// all see the same set. Each change bumps `version`, which the CrowPanel uses
/// to skip re-downloading an unchanged set.
@MainActor
public final class MuseumCardStore: ObservableObject {
    public static let shared = MuseumCardStore()

    public struct Snapshot: Codable {
        public var version: Int
        public var cards: [String: MuseumCard]
    }

    @Published public private(set) var snapshot = Snapshot(version: 0, cards: [:])

    private let fileURL: URL = {
        // `BLOOMING8_DATA_DIR` overrides the folder, for tests only.
        if let override = ProcessInfo.processInfo.environment["BLOOMING8_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("museum_cards.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Blooming8/museum_cards.json")
    }()

    private init() {
        reload()
        tidyCards()
    }

    /// Cleans up cards already stored, once per launch: decodes stray HTML
    /// entities everywhere, and — only for cards the user hasn't edited —
    /// shortens or drops titles that were copied in from a picture's embedded
    /// description (a 600-character block of AI-generator settings, say). Cards
    /// that end up with nothing left are removed. Cards edited by hand keep
    /// their wording.
    @discardableResult
    public func tidyCards() -> Int {
        var changed = 0
        for (path, card) in snapshot.cards {
            var cleaned = card.normalized()
            if !card.edited { cleaned.title = MuseumCardBuilder.cleanTitle(cleaned.title) }
            guard cleaned != card else { continue }
            changed += 1
            if cleaned.isEmpty {
                snapshot.cards.removeValue(forKey: path)
            } else {
                snapshot.cards[path] = cleaned
            }
        }
        if changed > 0 { persist() }
        return changed
    }

    /// Re-reads the file — the other product may have written to it.
    public func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        snapshot = loaded
    }

    public func card(for path: String) -> MuseumCard? {
        reload()
        return snapshot.cards[path]
    }

    /// Saves a hand-edited card. An all-empty card removes the entry.
    public func save(_ card: MuseumCard, for path: String) {
        reload()
        if card.isEmpty {
            snapshot.cards.removeValue(forKey: path)
        } else {
            var edited = card.normalized()
            edited.edited = true
            snapshot.cards[path] = edited
        }
        persist()
    }

    /// Stores an automatically generated card, unless the user has already
    /// written one for this path by hand.
    public func autoFill(_ card: MuseumCard, for path: String) {
        reload()
        if snapshot.cards[path]?.edited == true || card.isEmpty { return }
        snapshot.cards[path] = card.normalized()
        persist()
    }

    /// Reads the photo's metadata, looks up the place name, and stores the
    /// result as `path`'s card. Fire-and-forget from the send pipeline: a
    /// slow or failed place lookup must never hold up showing the photo.
    public func autoFill(path: String, metadata: PhotoMetadata?) {
        guard let metadata else { return }
        Task {
            let card = await MuseumCardBuilder.card(from: metadata)
            autoFill(card, for: path)
        }
    }

    /// The whole set as the JSON the CrowPanel downloads, plus the galleries
    /// it should leave out of its gallery picker.
    public func exportJSON(hiddenGalleries: [String]) -> Data {
        reload()
        struct Export: Encodable {
            let version: Int
            let cards: [String: MuseumCard]
            let hiddenGalleries: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let export = Export(version: snapshot.version, cards: snapshot.cards, hiddenGalleries: hiddenGalleries)
        return (try? encoder.encode(export)) ?? Data("{}".utf8)
    }

    private func persist() {
        snapshot.version = max(snapshot.version + 1, Int(Date().timeIntervalSince1970))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MuseumCardStore: couldn't save: \(error)")
        }
    }
}

/// The parts of a photo's EXIF/IPTC metadata a museum card is built from.
public struct PhotoMetadata: Sendable {
    public var title: String?
    public var dateTaken: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var cameraModel: String?
    public var focalLength35mm: Int?

    public init() {}

    /// Reads metadata from a local image file.
    public static func read(from url: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return read(source)
    }

    /// Reads metadata from original image bytes (e.g. a Photos-library
    /// export, which keeps the original's EXIF including GPS).
    public static func read(from data: Data) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return read(source)
    }

    private static func read(_ source: CGImageSource) -> PhotoMetadata? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var meta = PhotoMetadata()
        meta.title = [iptc[kCGImagePropertyIPTCObjectName], iptc[kCGImagePropertyIPTCCaptionAbstract], tiff[kCGImagePropertyTIFFImageDescription]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let raw = (exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            meta.dateTaken = formatter.date(from: raw)
        }

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            meta.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            meta.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !model.isEmpty {
            // "Canon" + "Canon EOS R6" → "Canon EOS R6"; "Apple" + "iPhone 15 Pro" → "iPhone 15 Pro".
            meta.cameraModel = (make.isEmpty || make == "Apple" || model.lowercased().hasPrefix(make.lowercased())) ? model : "\(make) \(model)"
        }
        meta.focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int

        let hasAnything = meta.title != nil || meta.dateTaken != nil || meta.latitude != nil || meta.cameraModel != nil
        return hasAnything ? meta : nil
    }
}

/// Turns raw metadata into display text.
public enum MuseumCardBuilder {
    public static func card(from meta: PhotoMetadata) async -> MuseumCard {
        var card = MuseumCard()
        card.title = cleanTitle(meta.title)
        if let date = meta.dateTaken {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
            card.date = formatter.string(from: date)
        }
        if let model = meta.cameraModel {
            card.camera = meta.focalLength35mm.map { "\(model) · \($0) mm" } ?? model
        }
        if let lat = meta.latitude, let lon = meta.longitude {
            card.place = await placeName(latitude: lat, longitude: lon) ?? ""
        }
        return card
    }

    /// A title fit for the little display, from a picture's embedded description:
    /// the first line only, capped at about 60 characters (cut at a word, with
    /// "…"), and nothing at all if it's really an AI image generator's settings
    /// ("Steps: 8, Sampler: …") or a prompt rather than a title.
    public static func cleanTitle(_ raw: String?) -> String {
        guard let raw else { return "" }
        let decoded = TextCleaning.decodeHTMLEntities(raw)
        let lowered = decoded.lowercased()
        let generatorMarkers = ["negative prompt:", "steps:", "sampler:", "cfg scale", "guidance scale:", "seed:"]
        if generatorMarkers.filter({ lowered.contains($0) }).count >= 2 { return "" }

        let firstLine = decoded.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var title = firstLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let limit = 60
        if title.count > limit {
            title = String(title.prefix(limit))
            if let space = title.lastIndex(of: " ") { title = String(title[..<space]) }
            while let last = title.last, ",;:-–—(".contains(last) { title.removeLast() }
            title += "…"
        }
        return title
    }

    /// "Landmark, City, Country" when Apple knows a point of interest there,
    /// otherwise "City, Country", otherwise "Region, Country".
    public static func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var parts: [String] = []
        if let landmark = placemark.areasOfInterest?.first { parts.append(landmark) }
        if let city = placemark.locality ?? placemark.subAdministrativeArea {
            parts.append(city)
        } else if let region = placemark.administrativeArea {
            parts.append(region)
        }
        if let country = placemark.country { parts.append(country) }
        // Drop repeats, e.g. a landmark that is also the city's name.
        var seen = Set<String>()
        parts = parts.filter { seen.insert($0).inserted }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
