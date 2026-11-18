import Foundation

/// One Bluetooth wake attempt: how long each step took, so a slowdown can be
/// measured rather than guessed at.
public struct WakeRecord: Codable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var succeeded: Bool
    public var deviceName: String
    /// Signal strength when the frame was found (dBm); nil if it never was.
    public var rssi: Int?
    /// Seconds from the start until the frame was seen, and until the link was up.
    public var foundSeconds: Double?
    public var connectedSeconds: Double?
    public var totalSeconds: Double
    /// True when the service-filtered scan found nothing and it fell back to scanning for any device.
    public var usedFallbackScan: Bool

    public init(date: Date, succeeded: Bool, deviceName: String, rssi: Int?, foundSeconds: Double?,
                connectedSeconds: Double?, totalSeconds: Double, usedFallbackScan: Bool) {
        self.date = date
        self.succeeded = succeeded
        self.deviceName = deviceName
        self.rssi = rssi
        self.foundSeconds = foundSeconds
        self.connectedSeconds = connectedSeconds
        self.totalSeconds = totalSeconds
        self.usedFallbackScan = usedFallbackScan
    }
}

/// The recent wake attempts, newest last, in one small file shared by the app
/// and the widget.
public enum WakeHistory {
    static let retention: TimeInterval = 30 * 86_400
    static let maximumRecords = 300

    private static var fileURL: URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["BLOOMING8_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            directory = base.appendingPathComponent("Blooming8", isDirectory: true)
        }
        return directory.appendingPathComponent("wake-history.json")
    }

    public static func load() -> [WakeRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([WakeRecord].self, from: data) else { return [] }
        return records.sorted { $0.date < $1.date }
    }

    /// `records` with `new` added, old ones and anything beyond the cap dropped.
    public static func adding(_ new: WakeRecord, to records: [WakeRecord], now: Date = Date()) -> [WakeRecord] {
        var all = records.filter { now.timeIntervalSince($0.date) < retention }
        all.append(new)
        all.sort { $0.date < $1.date }
        return Array(all.suffix(maximumRecords))
    }

    public static func record(_ new: WakeRecord) {
        let updated = adding(new, to: load())
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WakeHistory: couldn't save: %@", error.localizedDescription)
        }
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public struct Summary: Equatable {
        public var attempts: Int
        public var successes: Int
        /// Median total seconds across the successful attempts.
        public var medianSeconds: Double?
        public var medianRSSI: Int?
    }

    public static func summary(_ records: [WakeRecord]) -> Summary {
        let ok = records.filter(\.succeeded)
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return Summary(attempts: records.count, successes: ok.count,
                       medianSeconds: median(ok.map(\.totalSeconds)),
                       medianRSSI: median(records.compactMap { $0.rssi.map(Double.init) }).map { Int($0) })
    }
}
