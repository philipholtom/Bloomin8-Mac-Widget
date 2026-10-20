import Foundation

/// One battery reading from the frame.
public struct BatterySample: Codable, Equatable, Identifiable {
    public let date: Date
    public let percent: Int
    public var id: Date { date }

    public init(date: Date, percent: Int) {
        self.date = date
        self.percent = percent
    }
}

/// A running record of the frame's battery level, kept per frame profile in
/// `~/Library/Application Support/Blooming8/battery-<profile id>.json`.
///
/// Readings only exist while the frame is awake and answering (the app's
/// once-a-minute status check is what supplies them), so the record has gaps
/// wherever it was asleep or this Mac was off. That's fine for a trend line.
public enum BatteryHistory {
    /// How long readings are kept.
    static let retention: TimeInterval = 60 * 86_400
    /// A reading is only stored if the level changed, or at least this long
    /// has passed since the last one — the 60-second poll would otherwise
    /// write a thousand identical points a day.
    static let minimumGap: TimeInterval = 30 * 60

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
        directory.appendingPathComponent("battery-\(profileID.uuidString).json")
    }

    public static func load(profileID: UUID) -> [BatterySample] {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)),
              let samples = try? JSONDecoder().decode([BatterySample].self, from: data)
        else { return [] }
        return samples.sorted { $0.date < $1.date }
    }

    public static func save(_ samples: [BatterySample], profileID: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: fileURL(profileID: profileID), options: .atomic)
        } catch {
            NSLog("BatteryHistory: couldn't save: %@", error.localizedDescription)
        }
    }

    /// `samples` with a new reading added, or nil if this one isn't worth
    /// storing (same level as the last, and too soon after it). Readings
    /// older than the retention period are dropped.
    public static func recording(_ percent: Int, at date: Date, into samples: [BatterySample]) -> [BatterySample]? {
        if let last = samples.last, last.percent == percent, date.timeIntervalSince(last.date) < minimumGap {
            return nil
        }
        var updated = samples
        updated.append(BatterySample(date: date, percent: percent))
        let cutoff = date.addingTimeInterval(-retention)
        return updated.filter { $0.date >= cutoff }
    }

    /// A rough number of days until the battery runs out, from how fast it
    /// has been falling over the last week — or nil if there isn't enough to
    /// go on. Stretches where the level rose (charging) are left out, and
    /// time with no visible change counts as time spent draining.
    public static func daysRemaining(samples: [BatterySample], now: Date = Date()) -> Double? {
        let window = samples.filter { now.timeIntervalSince($0.date) <= 7 * 86_400 }
        guard window.count >= 2, let current = window.last?.percent else { return nil }

        var dropped = 0.0
        var hours = 0.0
        for (earlier, later) in zip(window, window.dropFirst()) {
            let elapsed = later.date.timeIntervalSince(earlier.date) / 3600
            guard elapsed > 0, later.percent <= earlier.percent else { continue }
            dropped += Double(earlier.percent - later.percent)
            hours += elapsed
        }
        guard hours >= 12, dropped >= 2 else { return nil }
        let perDay = dropped / hours * 24
        return Double(current) / perDay
    }
}
