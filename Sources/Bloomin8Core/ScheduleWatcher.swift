import AppKit
import Combine
import Foundation

/// The "days at a time" part of a schedule, as far as timing goes.
public struct ScheduleTiming: Equatable {
    public var days: Set<Weekday>
    public var timeMinutes: Int

    public init(days: Set<Weekday>, timeMinutes: Int) {
        self.days = days
        self.timeMinutes = timeMinutes
    }

    /// The first matching day/time strictly after `date`.
    public func next(after date: Date) -> Date? {
        let calendar = Calendar.current
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let candidate = occurrence(on: day), candidate > date else { continue }
            return candidate
        }
        return nil
    }

    /// The latest matching day/time at or before `date`.
    public func previous(atOrBefore date: Date) -> Date? {
        let calendar = Calendar.current
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
                  let candidate = occurrence(on: day), candidate <= date else { continue }
            return candidate
        }
        return nil
    }

    private func occurrence(on day: Date) -> Date? {
        let calendar = Calendar.current
        guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: day)), days.contains(weekday) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = timeMinutes / 60
        components.minute = timeMinutes % 60
        components.second = 0
        return calendar.date(from: components)
    }
}

/// Which occurrences of a schedule have already been run, shared by every
/// Bloomin8 process on this Mac — so the windowed app and the always-on
/// widget can both watch the same schedule and exactly one of them acts.
/// A claim is an exclusively-created empty file; whoever creates it wins.
public enum ScheduleClaim {
    /// True exactly once per (schedule, occurrence) across all processes.
    public static func claim(_ name: String, occurrence: Date) -> Bool {
        let folder = folderURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name)-\(Int(occurrence.timeIntervalSince1970))")
        let fd = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        prune(folder)
        return true
    }

    private static func folderURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["BLOOMING8_DATA_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("schedule-claims", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Blooming8/schedule-claims", isDirectory: true)
    }

    private static func prune(_ folder: URL) {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// Runs something at the scheduled times by looking at the real clock every
/// half minute and again whenever the Mac wakes — a plain `Timer` doesn't
/// count time spent asleep, so a schedule due while the lid was shut fired
/// late or never. An occurrence missed while asleep still runs on wake, as
/// long as it's no more than `maxLateness` old.
///
/// Several watchers (one per process) may watch the same schedule: each
/// occurrence is claimed through `ScheduleClaim`, and a watcher with a
/// non-zero `delay` only steps in if the primary hasn't already run it.
@MainActor
public final class ScheduleWatcher: ObservableObject {
    private let name: String
    private let delay: TimeInterval
    private let maxLateness: TimeInterval
    private let timing: () -> ScheduleTiming?
    private let run: () async -> Void

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastTiming: ScheduleTiming?
    private var hasLooked = false
    /// Occurrences at or before this are ignored — set when the schedule is
    /// edited, so enabling a 07:00 schedule at 10:00 doesn't fire at once.
    private var baseline: Date = .distantPast
    private var running = false

    /// When the schedule will next run, for display — nil if it's off.
    @Published public private(set) var nextFireDate: Date?

    /// - Parameters:
    ///   - timing: the schedule as it is NOW — nil when disabled or
    ///     incomplete. Called every tick, so it should read fresh settings.
    ///   - run: does the work; also responsible for re-reading its own settings.
    public init(name: String, delay: TimeInterval = 0, maxLateness: TimeInterval = 6 * 3600,
                timing: @escaping () -> ScheduleTiming?, run: @escaping () async -> Void) {
        self.name = name
        self.delay = delay
        self.maxLateness = maxLateness
        self.timing = timing
        self.run = run
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give networking a moment to come back before acting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                Task { @MainActor [weak self] in await self?.tick() }
            }
        }
        Task { await tick() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Re-reads the schedule and runs anything due. Internal-visible for tests.
    public func tick(now: Date = Date()) async {
        let current = timing()
        if current != lastTiming {
            // Edited (or first seen). Only a real edit resets the baseline,
            // not the first look at launch — a missed run should still catch up.
            if hasLooked { baseline = now }
            lastTiming = current
        }
        hasLooked = true
        guard let current else {
            nextFireDate = nil
            return
        }
        nextFireDate = current.next(after: now)
        guard !running,
              let due = current.previous(atOrBefore: now.addingTimeInterval(-delay)),
              due > baseline,
              now.timeIntervalSince(due) <= maxLateness,
              ScheduleClaim.claim(name, occurrence: due) else { return }
        running = true
        await run()
        running = false
        nextFireDate = current.next(after: Date())
    }
}
