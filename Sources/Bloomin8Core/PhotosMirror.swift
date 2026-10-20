import Foundation

/// A frame gallery kept in step with one album in the Photos app: photos
/// added to the album are uploaded to the gallery, and (if asked) photos
/// taken out of the album are removed from it. Set per frame profile; the
/// windowed app does the syncing, since it owns the Photos access.
public struct PhotosMirror: Codable, Equatable {
    /// Which photos of the album are mirrored.
    public enum Mode: String, Codable, CaseIterable, Identifiable {
        /// The newest `maxPhotos` in the album.
        case newest
        /// A random `maxPhotos`. The choice is kept between syncs (so the
        /// frame isn't reshuffled every half hour) until it's shuffled again.
        case random

        public var id: String { rawValue }
        public var label: String { self == .newest ? "Newest" : "Random" }
    }

    /// How often a random selection is replaced with a fresh one.
    public enum Reshuffle: String, Codable, CaseIterable, Identifiable {
        case never, daily, weekly

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .never: return "Only when I shuffle"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            }
        }
        public var interval: TimeInterval? {
            switch self {
            case .never: return nil
            case .daily: return 86_400
            case .weekly: return 7 * 86_400
            }
        }
    }

    /// Whether it syncs on its own (at launch, then every half hour while the
    /// app is open). "Sync Now" works either way.
    public var isEnabled: Bool
    /// `PHAssetCollection.localIdentifier`.
    public var albumID: String
    public var albumTitle: String
    /// The gallery on the frame that follows the album.
    public var gallery: String
    /// How many photos are mirrored (the newest this many, or this many random ones).
    public var maxPhotos: Int
    public var mode: Mode
    public var reshuffle: Reshuffle
    /// Also delete from the gallery photos that are no longer in the album
    /// (or, in random mode, no longer in the chosen set). Only ever touches
    /// photos this mirror itself uploaded.
    public var removeDeleted: Bool

    public static let photoCountChoices = [10, 20, 30, 50, 100, 200, 500]

    public init(
        isEnabled: Bool = false,
        albumID: String = "",
        albumTitle: String = "",
        gallery: String = "",
        maxPhotos: Int = 100,
        mode: Mode = .newest,
        reshuffle: Reshuffle = .never,
        removeDeleted: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.gallery = gallery
        self.maxPhotos = maxPhotos
        self.mode = mode
        self.reshuffle = reshuffle
        self.removeDeleted = removeDeleted
    }

    // Written out so a mirror saved by an earlier build (without `mode` or
    // `reshuffle`) still loads, as "newest".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        albumID = try c.decodeIfPresent(String.self, forKey: .albumID) ?? ""
        albumTitle = try c.decodeIfPresent(String.self, forKey: .albumTitle) ?? ""
        gallery = try c.decodeIfPresent(String.self, forKey: .gallery) ?? ""
        maxPhotos = try c.decodeIfPresent(Int.self, forKey: .maxPhotos) ?? 100
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .newest
        reshuffle = try c.decodeIfPresent(Reshuffle.self, forKey: .reshuffle) ?? .never
        removeDeleted = try c.decodeIfPresent(Bool.self, forKey: .removeDeleted) ?? false
    }

    /// Whether `filename` is one a mirror uploads (`album-<key>_P.jpg`), as
    /// opposed to a photo someone put in the same gallery by hand.
    public static func isMirrorFilename(_ filename: String) -> Bool {
        filename.range(of: "^album-[0-9a-f]{8}_[PL]\\.jpg$", options: .regularExpression) != nil
    }
}

/// What a mirror remembers between syncs, per frame profile, in
/// `~/Library/Application Support/Blooming8/`: the files it believes are on
/// the frame (so an automatic check can tell "nothing has changed in the
/// album" without waking or even contacting the frame), and — in random mode —
/// which photos it chose and when.
public struct PhotosMirrorState: Codable, Equatable {
    /// Filenames the mirror last left on the frame.
    public var names: Set<String> = []
    /// Random mode: the asset IDs currently chosen.
    public var selection: [String] = []
    public var lastShuffle: Date?

    public init() {}

    /// `BLOOMING8_DATA_DIR` overrides the folder, for tests only.
    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BLOOMING8_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Blooming8", isDirectory: true)
    }

    private static func fileURL(profileID: UUID) -> URL {
        directory.appendingPathComponent("photos-mirror-\(profileID.uuidString).json")
    }

    public static func load(profileID: UUID) -> PhotosMirrorState {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)) else { return PhotosMirrorState() }
        if let state = try? JSONDecoder().decode(PhotosMirrorState.self, from: data) { return state }
        // The first version stored just the list of filenames.
        var legacy = PhotosMirrorState()
        if let names = try? JSONDecoder().decode([String].self, from: data) { legacy.names = Set(names) }
        return legacy
    }

    public static func save(_ state: PhotosMirrorState, profileID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL(profileID: profileID), options: .atomic)
        } catch {
            NSLog("PhotosMirrorState: couldn't save: %@", error.localizedDescription)
        }
    }

    /// Chooses which asset IDs to mirror in random mode: keeps the earlier
    /// choice for as long as those photos are still in the album, tops it up
    /// with random ones if it's short (or the album grew), and starts afresh
    /// when `reshuffle` is set. Pure, so it can be tested.
    public static func randomSelection(
        albumIDs: [String],
        previous: [String],
        count: Int,
        reshuffle: Bool,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        let inAlbum = Set(albumIDs)
        var chosen = reshuffle ? [] : previous.filter(inAlbum.contains)
        if chosen.count > count { chosen = Array(chosen.prefix(count)) }
        if chosen.count < count {
            let taken = Set(chosen)
            let pool = albumIDs.filter { !taken.contains($0) }.shuffled(using: &generator)
            chosen += pool.prefix(count - chosen.count)
        }
        return chosen
    }
}

extension PhotoController {
    /// The on-frame filename a mirror gives a Photos asset: always the same for
    /// the same photo and render settings, so a photo already uploaded is
    /// recognised next time instead of being uploaded again.
    public func mirrorFilename(forPhotosAsset assetID: String) -> String {
        let key = Self.sourceKey(forPhotosAsset: assetID, cropLandscapePhotos: settings.cropLandscapePhotos, width: settings.renderWidth, height: settings.renderHeight)
        return orientedFilename("album-\(key)")
    }

    /// Every photo name in a gallery on the frame (waking it if needed).
    /// A gallery that doesn't exist yet lists as empty.
    public func listFrameGallery(_ gallery: String) async throws -> [String] {
        try await withWakeRetry { try await client.fetchAllImages(ip: settings.deviceIP, gallery: gallery) }
    }

    public func ensureFrameGallery(_ gallery: String) async {
        await client.ensureGallery(ip: settings.deviceIP, name: gallery)
    }

    /// Renders up to a handful of photos (as raw image bytes) for the frame and
    /// uploads them together, falling back to one at a time for any the
    /// batch didn't confirm. Returns the filenames that did not make it.
    public func uploadPhotoBatch(_ items: [(filename: String, data: Data)], to gallery: String) async -> [String] {
        let width = settings.renderWidth
        let height = settings.renderHeight
        let crop = settings.cropLandscapePhotos
        let rendered: [(filename: String, data: Data)?] = await Task.detached(priority: .userInitiated) { [weak self] in
            items.map { item in
                guard let cgImage = loadUprightCGImage(data: item.data),
                      let framed = self?.renderForFrame(cgImage: cgImage, width: width, height: height, cropLandscapePhotos: crop),
                      let jpeg = ImageCanvas.jpegData(framed)
                else { return nil }
                return (item.filename, jpeg)
            }
        }.value

        var failed: [String] = []
        var files: [(filename: String, data: Data)] = []
        for (index, item) in rendered.enumerated() {
            if let item { files.append(item) } else { failed.append(items[index].filename) }
        }
        guard !files.isEmpty else { return failed }

        var confirmed: Set<String> = []
        if let names = try? await client.uploadImages(ip: settings.deviceIP, gallery: gallery, files: files) {
            confirmed = Set(names)
        }
        for file in files where !confirmed.contains(file.filename) {
            do {
                _ = try await client.uploadImage(ip: settings.deviceIP, filename: file.filename, gallery: gallery, imageData: file.data, showNow: false)
            } catch {
                failed.append(file.filename)
            }
        }
        return failed
    }

    /// Deletes the named photos from a frame gallery; returns how many went.
    public func removeFromFrameGallery(_ gallery: String, filenames: [String]) async -> Int {
        var removed = 0
        for name in filenames {
            if (try? await client.deleteImage(ip: settings.deviceIP, filename: name, gallery: gallery)) != nil { removed += 1 }
        }
        return removed
    }
}
