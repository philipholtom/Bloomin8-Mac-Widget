import Foundation

/// One picture that has been on the frame.
public struct ShownEntry: Codable, Equatable, Identifiable {
    /// Its path on the frame, e.g. `/gallerys/Family/x_P.jpg`.
    public let path: String
    public var shownAt: Date
    public var id: String { path }

    public init(path: String, shownAt: Date) {
        self.path = path
        self.shownAt = shownAt
    }
}

/// What has recently been on the frame, newest first, kept per frame profile in
/// `~/Library/Application Support/Blooming8/shown-<profile id>.json`.
///
/// A picture is noted whenever this Mac learns it's on the frame — sent from
/// here, or seen by the once-a-minute status check, so changes the frame made
/// itself (a slideshow, a playlist, the hourly pull) show up too while the app
/// or widget is running. A picture shown again moves to the top rather than
/// appearing twice.
public enum ShownHistory {
    static let limit = 150

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
        directory.appendingPathComponent("shown-\(profileID.uuidString).json")
    }

    public static func load(profileID: UUID) -> [ShownEntry] {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)),
              let entries = try? JSONDecoder().decode([ShownEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.shownAt > $1.shownAt }
    }

    public static func save(_ entries: [ShownEntry], profileID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL(profileID: profileID), options: .atomic)
        } catch {
            NSLog("ShownHistory: couldn't save: %@", error.localizedDescription)
        }
    }

    /// `entries` with `path` at the top, or nil if it's already the newest
    /// (nothing to change). Anything past the limit is dropped.
    public static func recording(_ path: String, at date: Date, into entries: [ShownEntry]) -> [ShownEntry]? {
        guard !path.isEmpty, entries.first?.path != path else { return nil }
        var updated = entries.filter { $0.path != path }
        updated.insert(ShownEntry(path: path, shownAt: date), at: 0)
        return Array(updated.prefix(limit))
    }
}
