import AppKit
import Combine
import CryptoKit

@MainActor
public final class PhotoController: ObservableObject {
    public let settings: AppSettings
    let client = BloominClient()
    private let bleWaker = BLEWaker()

    @Published public var previewImage: NSImage?
    /// Raw bytes behind `previewImage`, kept alongside it so "Save Photo"
    /// can write the exact original file rather than a re-encoded copy.
    @Published public var currentImageData: Data?
    @Published public var currentImagePath: String?
    /// The local file the image currently on the frame came from, if it was
    /// sent from one (Local Folder browsing, Random from Local Folder, a
    /// video frame) — nil for anything device-sourced (Random Photo, Show
    /// Next, a gallery browse) or from Apple Photos, which has no real local
    /// file to point to. Lets "Add to Favorites" on the Frame pane offer
    /// favoriting only when it's actually meaningful, matching how
    /// Favorites works everywhere else in the app (real local files only).
    @Published public var currentLocalSourceURL: URL?
    @Published public var deviceName: String?
    /// The whole of the frame's last `/deviceInfo` answer, for the status panel.
    @Published public private(set) var deviceInfo: DeviceInfo?
    @Published public var batteryPercent: Int?
    @Published public var currentGalleryOnDevice: String?
    @Published public var galleries: [String] = []
    @Published public var sleepDurationSeconds: Int?
    @Published public var maxIdleSeconds: Int?
    @Published public var wakeSensitivity: Int?
    @Published public var statusText: String = ""
    @Published public var isBusy: Bool = false
    /// Tabs unlocked this app session (in-memory only — re-locks on relaunch).
    @Published public var unlockedTabIDs: Set<UUID> = []
    /// Whether the shared Local Folder / Favorites password has been entered
    /// this app session (in-memory only — re-locks on relaunch, same as
    /// `unlockedTabIDs`). One password gates both, since they're really the
    /// same "your private local photos" concern — unlocking either one in
    /// the windowed app unlocks both there. The widget uses
    /// `settings.localFolderLocked`/`localFolderPasswordHash` too, but only
    /// gates its own Local Folder tab; this doesn't reach into the widget's
    /// separate per-process unlock state, same as tab unlocking doesn't.
    @Published public var isLocalFolderUnlocked: Bool = false
    /// Whether locked tabs are currently shown in the tab bar at all — off by
    /// default so they don't appear to a casual viewer of the popover, toggled
    /// with a keyboard shortcut, and reset to hidden whenever the popover
    /// closes so it doesn't stay revealed for the next person who opens it.
    @Published public var showHiddenTabs: Bool = false
    /// When the next automatic random photo is scheduled to fire, if enabled.
    @Published public var nextAutoRandomFireDate: Date?
    /// Whether the frame answered the last reachability check — nil means no
    /// device IP is set yet, or the first check hasn't completed.
    @Published public var isDeviceAwake: Bool?
    /// Most-recent-first log of upload/show/delete/device-setting/scheduled-
    /// send/keep-awake outcomes, for the toolbar Activity sheet — see
    /// ActivityEvent.swift.
    @Published public var recentActivity: [ActivityEvent] = []
    /// The active frame's battery readings over time — see `BatteryHistory`.
    @Published public private(set) var batterySamples: [BatterySample] = []
    private var batteryProfileCancellable: AnyCancellable?
    /// True once a failure has landed in `recentActivity` that the Activity
    /// sheet hasn't been opened to see yet; cleared when it's opened.
    @Published public var hasUnseenActivityFailure: Bool = false

    /// Keeps the frame from idling into sleep by calling its `/whistle`
    /// keep-alive on a timer while on. Deliberately runtime-only (never
    /// persisted, and per process): a forgotten "stay awake" quietly
    /// draining a battery-powered frame overnight is worse than having to
    /// switch it on again after a relaunch. Switching profiles turns it off.
    @Published public var keepAwake: Bool = false {
        didSet {
            guard keepAwake != oldValue else { return }
            keepAwakeGeneration += 1
            keepAwakeTimer?.invalidate()
            keepAwakeTimer = nil
            keepAwakeFailures = 0
            if keepAwake { Task { await startKeepAwake(generation: keepAwakeGeneration) } }
        }
    }
    private var keepAwakeTimer: Timer?
    private var keepAwakeFailures = 0
    /// Bumped on every toggle so a start/tick still in flight from an earlier
    /// on/off can tell it's stale and do nothing.
    private var keepAwakeGeneration = 0
    /// Stop keeping it awake below this battery level; the frame's own
    /// low-battery behaviour matters more than staying awake.
    private static let keepAwakeMinimumBattery = 15

    /// Looks at the wall clock every 30 seconds (and on wake) rather than
    /// being a one-shot timer, because a one-shot `Timer` doesn't count the
    /// time the Mac spends asleep — see `ScheduleWatcher`.
    private var autoRandomTimer: Timer?
    private var autoRandomWakeObserver: NSObjectProtocol?
    /// Daily occurrences at or before this are ignored: set when the setting
    /// is edited so changing the time to one already passed doesn't fire.
    private var autoRandomBaseline: Date = .distantPast
    private var autoRandomHasStarted = false
    private var autoRandomRunning = false
    private var autoRandomCancellable: AnyCancellable?
    private var statusPollTimer: Timer?
    private var statusPollCancellable: AnyCancellable?

    private struct AutoRandomTrigger: Equatable {
        let enabled: Bool
        let interval: AutoRandomInterval
        let dailyMinute: Int
        let deviceIP: String
    }

    public init(settings: AppSettings) {
        self.settings = settings
        // Re-evaluate the schedule whenever any relevant setting changes —
        // including switching the active frame profile entirely, since
        // autoRandomEnabled/Interval/DailyMinute and deviceIP are now
        // per-profile — and once immediately (Combine's sink fires with the
        // current value right after subscribing) so the schedule is live
        // from app launch.
        //
        // Subscribes to `$frameProfiles`/`$activeFrameProfileID` (the only
        // genuinely `@Published` storage backing these per-frame values now)
        // rather than the individual settings, since those are computed
        // proxies with no publisher of their own. But `frameProfiles` now
        // backs EVERY per-frame setting, not just the ones these two timers
        // care about — favorites, tabs, scheduledSend, galleries, dimensions,
        // all of it — so subscribing to the raw array republished on every
        // unrelated change and re-triggered `updateStatusPollSchedule()`
        // (which fires an immediate extra `/deviceInfo` request) on every
        // single settings write, not just an actual deviceIP/auto-random
        // change. The frame's embedded HTTP server is already known to be
        // slow and doesn't handle overlapping requests well, so this flooded
        // it and surfaced as timeout errors during ordinary use — nothing to
        // do with the frame itself. `.map` down to just the fields each
        // timer actually depends on, then `.removeDuplicates()`, restores
        // "only fires when something relevant actually changed."
        //
        // Deferred to the next run loop turn either way: `@Published`
        // publishes from `willSet`, before the backing storage is actually
        // updated, so a synchronous `settings.X` read inside this sink would
        // see the value from BEFORE whatever change just triggered it — the
        // same class of bug already found and fixed in ScheduledSendManager.
        autoRandomCancellable = Publishers.CombineLatest(settings.$frameProfiles, settings.$activeFrameProfileID)
            .map { profiles, activeID -> AutoRandomTrigger in
                let profile = profiles.first(where: { $0.id == activeID })
                return AutoRandomTrigger(
                    enabled: profile?.autoRandomEnabled ?? false,
                    interval: profile?.autoRandomInterval ?? .hourly,
                    dailyMinute: profile?.autoRandomDailyMinute ?? 0,
                    deviceIP: profile?.deviceIP ?? ""
                )
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateAutoRandomSchedule()
                }
            }

        // Each frame has its own battery record, so switching profiles loads
        // that frame's. (Fires once straight away with the current profile.)
        batteryProfileCancellable = settings.$activeFrameProfileID
            .removeDuplicates()
            .sink { [weak self] id in
                self?.batterySamples = BatteryHistory.load(profileID: id)
            }

        statusPollCancellable = Publishers.CombineLatest(settings.$frameProfiles, settings.$activeFrameProfileID)
            .map { profiles, activeID in profiles.first(where: { $0.id == activeID })?.deviceIP ?? "" }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateStatusPollSchedule()
                }
            }
    }

    /// Seconds between whistles, from the frame's own idle timeout
    /// (`/deviceInfo`'s `max_idle`, 120s on this frame): comfortably inside
    /// it — a request to this slow server can itself take a few seconds — but
    /// no more often than needed, since every call costs the battery.
    private var keepAwakeInterval: TimeInterval {
        min(max(Double(maxIdleSeconds ?? 120) * 0.4, 10), 60)
    }

    private func startKeepAwake(generation: Int) async {
        guard !settings.deviceIP.isEmpty else {
            statusText = "Set the frame's IP address first."
            keepAwake = false
            return
        }
        // The first whistle also wakes a frame that's already asleep (over
        // Bluetooth); later ones don't, so an unreachable frame doesn't
        // trigger a wake-and-scan every cycle.
        do {
            try await withWakeRetry { try await client.whistle(ip: settings.deviceIP) }
        } catch {
            guard generation == keepAwakeGeneration else { return }
            statusText = "Couldn't keep the frame awake: \(error.localizedDescription)"
            logActivity("Keep Awake: couldn't reach the frame — \(error.localizedDescription)", success: false)
            keepAwake = false
            return
        }
        guard generation == keepAwakeGeneration else { return }
        statusText = "Keeping the frame awake."
        scheduleNextWhistle(generation: generation)
    }

    private func scheduleNextWhistle(generation: Int) {
        keepAwakeTimer = Timer.scheduledTimer(withTimeInterval: keepAwakeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.whistleTick(generation: generation)
            }
        }
    }

    private func whistleTick(generation: Int) async {
        guard generation == keepAwakeGeneration, keepAwake else { return }
        if let battery = batteryPercent, battery <= Self.keepAwakeMinimumBattery {
            statusText = "Stopped keeping the frame awake: its battery is at \(battery)%."
            logActivity("Keep Awake: stopped — battery at \(battery)%.", success: true)
            keepAwake = false
            return
        }
        do {
            try await client.whistle(ip: settings.deviceIP)
            keepAwakeFailures = 0
        } catch {
            keepAwakeFailures += 1
            // The frame wakes by itself at the top of each hour for its
            // scheduled pull and then shuts down whatever the keep-alive
            // says (seen in its log: "Initiate pull request … Shutdown" a
            // second or two apart). Rather than give up there, wake it
            // again over Bluetooth after the second miss — one wake pulse,
            // not one per cycle — and carry on.
            if keepAwakeFailures == 2, !settings.bleDeviceName.isEmpty {
                if (try? await withWakeRetry { try await client.whistle(ip: settings.deviceIP) }) != nil {
                    keepAwakeFailures = 0
                    logActivity("Keep Awake: the frame went to sleep (its scheduled refresh) — woke it again.", success: true)
                    guard generation == keepAwakeGeneration else { return }
                    scheduleNextWhistle(generation: generation)
                    return
                }
            }
            if keepAwakeFailures >= 4 {
                statusText = "Stopped keeping the frame awake: it stopped responding."
                logActivity("Keep Awake: stopped — the frame stopped responding.", success: false)
                keepAwake = false
                return
            }
        }
        guard generation == keepAwakeGeneration else { return }
        scheduleNextWhistle(generation: generation)
    }

    /// (Re)starts the periodic awake/asleep check to match the current
    /// device IP. Always cancels any pending timer first.
    private func updateStatusPollSchedule() {
        // Only reached when the frame being controlled changes (or at
        // launch): a keep-awake for the previous frame doesn't carry over.
        if keepAwake { keepAwake = false }
        statusPollTimer?.invalidate()
        statusPollTimer = nil
        guard !settings.deviceIP.isEmpty else {
            isDeviceAwake = nil
            return
        }
        Task { await pollDeviceStatus() }
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollDeviceStatus()
            }
        }
    }

    /// A lightweight reachability check for the menu bar/popover status
    /// indicator. Deliberately does not go through withWakeRetry's BLE wake
    /// pulse — the whole point is to notice the frame is asleep, not to wake
    /// it up just to check.
    private func pollDeviceStatus() async {
        guard !settings.deviceIP.isEmpty else { return }
        do {
            let info = try await client.fetchDeviceInfo(ip: settings.deviceIP)
            applyDeviceInfo(info)
        } catch {
            isDeviceAwake = false
        }
    }

    /// (Re)starts or stops the auto-random timer to match current settings.
    /// Safe to call any time settings change — always cancels any pending fire first.
    private func updateAutoRandomSchedule() {
        autoRandomTimer?.invalidate()
        autoRandomTimer = nil
        if let observer = autoRandomWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            autoRandomWakeObserver = nil
        }
        // The first call is launch: a daily change missed while the app
        // wasn't running may still catch up. Later calls are edits.
        autoRandomBaseline = autoRandomHasStarted ? Date() : .distantPast
        autoRandomHasStarted = true
        guard settings.autoRandomEnabled, !settings.deviceIP.isEmpty else {
            nextAutoRandomFireDate = nil
            return
        }
        nextAutoRandomFireDate = settings.autoRandomInterval == .hourly
            ? Date().addingTimeInterval(3600)
            : dailyTiming.next(after: Date())
        autoRandomTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.autoRandomTick() }
        }
        autoRandomWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Let networking come back before acting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                Task { @MainActor [weak self] in await self?.autoRandomTick() }
            }
        }
        Task { await autoRandomTick() }
    }

    private var dailyTiming: ScheduleTiming {
        ScheduleTiming(days: Set(Weekday.allCases), timeMinutes: settings.autoRandomDailyMinute)
    }

    /// Runs the random photo if it's due by the real clock. Hourly: an hour
    /// after the last one (or on wake, if that hour passed while asleep).
    /// Daily: at the set time, or on wake if it was missed by under 6 hours —
    /// claimed through `ScheduleClaim` so the widget and the windowed app,
    /// which each run this, don't both change the photo.
    func autoRandomTick(now: Date = Date()) async {
        guard settings.autoRandomEnabled, !settings.deviceIP.isEmpty, !autoRandomRunning else { return }
        if settings.autoRandomInterval == .hourly {
            guard let next = nextAutoRandomFireDate, now >= next else { return }
        } else {
            let timing = dailyTiming
            nextAutoRandomFireDate = nextAutoRandomFireDate ?? timing.next(after: now)
            guard let due = timing.previous(atOrBefore: now),
                  due > autoRandomBaseline,
                  now.timeIntervalSince(due) <= 6 * 3600,
                  ScheduleClaim.claim("auto-random-\(settings.activeFrameProfileID.uuidString)", occurrence: due)
            else {
                if let next = nextAutoRandomFireDate, now >= next { nextAutoRandomFireDate = timing.next(after: now) }
                return
            }
        }
        autoRandomRunning = true
        await showRandomPhoto()
        autoRandomRunning = false
        nextAutoRandomFireDate = settings.autoRandomInterval == .hourly
            ? Date().addingTimeInterval(3600)
            : dailyTiming.next(after: Date())
    }

    /// Every gallery name that's currently selectable for randomization: ones
    /// not assigned to any tab, plus ones in tabs that are unlocked (or have
    /// no password). Galleries in a still-locked tab are excluded even if
    /// they were checked before the tab got locked.
    public var availableGalleryNames: Set<String> {
        let assigned = Set(settings.tabs.flatMap { $0.galleryNames })
        var available = Set(galleries).subtracting(assigned)
        for tab in settings.tabs where !tab.isLocked || unlockedTabIDs.contains(tab.id) {
            available.formUnion(tab.galleryNames)
        }
        return available
    }

    @discardableResult
    public func unlock(tab: GalleryTab, password: String) -> Bool {
        guard let hash = tab.passwordHash else {
            unlockedTabIDs.insert(tab.id)
            return true
        }
        let result = PasswordHasher.verify(password, against: hash)
        guard result.matched else { return false }
        if let upgraded = result.upgradedHash, let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
            // The stored hash was still in the old unsalted format — swap
            // in a freshly-salted one now that the password's been proven
            // correct, so this tab isn't re-verified against the weak
            // format again next time.
            settings.tabs[index].passwordHash = upgraded
        }
        unlockedTabIDs.insert(tab.id)
        return true
    }

    public func loadGalleries() async {
        guard !settings.deviceIP.isEmpty else { return }
        do {
            let names = try await client.fetchGalleryList(ip: settings.deviceIP)
            galleries = names
            // Drop any previously-selected galleries that no longer exist on the device.
            settings.selectedGalleries.formIntersection(names)
            if settings.selectedGalleries.isEmpty {
                let fallback = currentGalleryOnDevice.flatMap { names.contains($0) ? $0 : nil } ?? names.first
                settings.selectedGalleries = fallback.map { [$0] } ?? []
            }
        } catch {
            statusText = "Couldn't load galleries: \(error.localizedDescription)"
        }
    }

    /// Uploads local image files into a gallery, letterbox-fitting each into
    /// the frame's 1200x1600 canvas and converting to JPEG first (the frame's
    /// /upload endpoint expects JPEG; this also avoids the frame cropping a
    /// mismatched aspect ratio to fill its screen, and color-manages
    /// wide-gamut/HDR sources like HEIC correctly). Creates the gallery if it
    /// doesn't already exist. Does not display any of them — this is a bulk
    /// import, not a "show now" action.
    ///
    /// With `deterministicNames`, each file is named from its content key
    /// (the same `base-<key>` scheme single sends use) instead of a timestamp,
    /// so uploading the same photo again overwrites it rather than adding a
    /// duplicate.
    public func uploadPhotos(urls: [URL], gallery: String, deterministicNames: Bool = false) async {
        let trimmedGallery = gallery.trimmingCharacters(in: .whitespaces)
        guard !trimmedGallery.isEmpty else {
            statusText = "Choose or type a gallery to upload into."
            return
        }
        guard !urls.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)
            await client.ensureGallery(ip: settings.deviceIP, name: trimmedGallery)

            var uploaded = 0
            var failed = 0
            // Batches ride one /image/uploadMulti request each (about 3.5x
            // faster than one request per photo on the real frame); small
            // enough that a failed batch is cheap to retry photo-by-photo.
            let batchSize = 5
            var start = 0
            while start < urls.count {
                let end = min(start + batchSize, urls.count)
                var batch: [(filename: String, data: Data)] = []
                var sourceURLs: [String: URL] = [:]
                let batchURLs = Array(urls[start..<end])
                statusText = "Preparing photos \(start + 1)–\(end) of \(urls.count)..."
                // Decoding and rendering full-size photos is the slow part;
                // do the whole batch off the main thread so the window stays
                // responsive during a big import.
                let renderWidth = settings.renderWidth
                let renderHeight = settings.renderHeight
                let cropLandscapePhotos = settings.cropLandscapePhotos
                let rendered: [Data?] = await Task.detached(priority: .userInitiated) { [weak self] in
                    batchURLs.map { url in
                        guard let cgImage = loadUprightCGImage(at: url),
                              let framed = self?.renderForFrame(cgImage: cgImage, width: renderWidth, height: renderHeight, cropLandscapePhotos: cropLandscapePhotos)
                        else { return nil }
                        return ImageCanvas.jpegData(framed)
                    }
                }.value
                for (offset, jpeg) in rendered.enumerated() {
                    guard let jpeg else {
                        failed += 1
                        continue
                    }
                    let url = batchURLs[offset]
                    let baseName = sanitizeFilenameComponent(url.deletingPathExtension().lastPathComponent)
                    let filename: String
                    if deterministicNames {
                        filename = deterministicFilename(for: url)
                    } else {
                        filename = orientedFilename("\(baseName)_\(Int(Date().timeIntervalSince1970 * 1000))_\(start + offset)")
                    }
                    batch.append((filename, jpeg))
                    sourceURLs[filename] = url
                }
                start = end
                guard !batch.isEmpty else { continue }

                statusText = "Uploading \(uploaded + failed + 1)–\(uploaded + failed + batch.count) of \(urls.count)..."
                var confirmed: Set<String> = []
                if let names = try? await client.uploadImages(ip: settings.deviceIP, gallery: trimmedGallery, files: batch) {
                    confirmed = Set(names)
                }
                for file in batch {
                    // Anything the batch didn't confirm (or the whole batch, if
                    // it failed outright) gets the proven single-file path.
                    let cardPath = "/gallerys/\(trimmedGallery)/\(file.filename)"
                    if confirmed.contains(file.filename) || confirmed.contains(file.filename + ".jpg") {
                        uploaded += 1
                        MuseumCardStore.shared.autoFill(path: cardPath, metadata: sourceURLs[file.filename].flatMap(PhotoMetadata.read(from:)))
                        continue
                    }
                    do {
                        _ = try await client.uploadImage(ip: settings.deviceIP, filename: file.filename, gallery: trimmedGallery, imageData: file.data, showNow: false)
                        uploaded += 1
                        MuseumCardStore.shared.autoFill(path: cardPath, metadata: sourceURLs[file.filename].flatMap(PhotoMetadata.read(from:)))
                    } catch {
                        failed += 1
                    }
                }
            }
            let failedSuffix = failed > 0 ? " (\(failed) failed)" : ""
            statusText = "Uploaded \(uploaded) of \(urls.count) photo\(urls.count == 1 ? "" : "s") to '\(trimmedGallery)'\(failedSuffix)."
            logActivity("Uploaded \(uploaded) of \(urls.count) photo\(urls.count == 1 ? "" : "s") to '\(trimmedGallery)'\(failedSuffix)", success: failed == 0)
            await loadGalleries()
        } catch {
            statusText = "Couldn't upload: \(error.localizedDescription)"
            logActivity("Couldn't upload to '\(trimmedGallery)': \(error.localizedDescription)", success: false)
        }
    }

    /// The on-frame filename a local photo gets when sent with a stable name:
    /// the same `base-<key>` scheme as single sends (confirmLocalFolderCandidate),
    /// so the same photo with the same render settings always maps to the same
    /// file — which is what lets "already on the frame?" checks and repeated
    /// imports skip or overwrite instead of piling up copies.
    private func deterministicFilename(for url: URL) -> String {
        let base = sanitizeFilenameComponent(url.deletingPathExtension().lastPathComponent)
        // `sourceKey` is nil only if the file can't be stat'ed; a hash of its
        // path keeps the name valid and stable in that case too.
        let key = Self.sourceKey(forFile: url, cropLandscapePhotos: settings.cropLandscapePhotos, width: settings.renderWidth, height: settings.renderHeight)
            ?? Self.shortHash(url.path)
        return orientedFilename("\(base)-\(key)")
    }

    /// Picks up to `count` random photos from `folder` (and every subfolder)
    /// that aren't already in `gallery`, and uploads them there — so the
    /// frame's own slideshow of that gallery can run without this Mac.
    /// Safe to run repeatedly: photos already uploaded this way are
    /// recognised by their stable filename and skipped, so each run adds
    /// *new* ones rather than duplicating.
    public func addRandomPhotos(from folder: URL, count: Int, to gallery: String) async {
        let trimmedGallery = gallery.trimmingCharacters(in: .whitespaces)
        guard !trimmedGallery.isEmpty, count > 0 else { return }
        isBusy = true
        statusText = "Looking for photos in '\(folder.lastPathComponent)'…"
        let candidates = await Task.detached(priority: .userInitiated) {
            ImageFolder.enumerateImages(in: folder).shuffled()
        }.value
        guard !candidates.isEmpty else {
            isBusy = false
            statusText = "No photos found in '\(folder.lastPathComponent)'."
            logActivity("No photos found in '\(folder.lastPathComponent)'", success: false)
            return
        }

        // What's already there. A gallery that doesn't exist yet just has
        // nothing in it; a frame that can't be reached is caught by the
        // upload itself right after.
        let existing = Set((try? await withWakeRetry { try await client.fetchAllImages(ip: settings.deviceIP, gallery: trimmedGallery) }) ?? [])

        var chosen: [URL] = []
        var alreadyThere = 0
        for url in candidates {
            if existing.contains(deterministicFilename(for: url)) {
                alreadyThere += 1
                continue
            }
            chosen.append(url)
            if chosen.count == count { break }
        }
        isBusy = false

        guard !chosen.isEmpty else {
            statusText = "Every photo I tried from '\(folder.lastPathComponent)' is already in '\(trimmedGallery)'."
            logActivity("Nothing new to add to '\(trimmedGallery)' from '\(folder.lastPathComponent)'", success: true)
            return
        }
        await uploadPhotos(urls: chosen, gallery: trimmedGallery, deterministicNames: true)
    }

    /// Downloads every photo in a gallery into a subfolder (named after the
    /// gallery) inside the chosen destination folder.
    public func downloadGallery(_ gallery: String, to folder: URL) async {
        guard !gallery.isEmpty else {
            statusText = "Choose a gallery to download."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)
            let names = try await client.fetchAllImages(ip: settings.deviceIP, gallery: gallery)
            guard !names.isEmpty else {
                statusText = "'\(gallery)' has no photos to download."
                return
            }

            let destination = folder.appendingPathComponent(gallery, isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var downloaded = 0
            var failed = 0
            for (index, name) in names.enumerated() {
                statusText = "Downloading \(name) (\(index + 1)/\(names.count))..."
                do {
                    let data = try await client.fetchImageData(ip: settings.deviceIP, path: "/gallerys/\(gallery)/\(name)")
                    try data.write(to: destination.appendingPathComponent(name))
                    downloaded += 1
                } catch {
                    failed += 1
                }
            }
            let failedSuffix = failed > 0 ? " (\(failed) failed)" : ""
            statusText = "Downloaded \(downloaded) of \(names.count) photo\(names.count == 1 ? "" : "s") to \(destination.path)\(failedSuffix)."
            logActivity("Downloaded \(downloaded) of \(names.count) photo\(names.count == 1 ? "" : "s") from '\(gallery)'\(failedSuffix)", success: downloaded == names.count)
        } catch {
            statusText = "Couldn't download: \(error.localizedDescription)"
            logActivity("Couldn't download '\(gallery)': \(error.localizedDescription)", success: false)
        }
    }

    /// Sends a Bluetooth wake pulse on demand (e.g. from a button or menu item),
    /// independent of any HTTP call failing first.
    @discardableResult
    public func wakeFrame() async -> Bool {
        guard !settings.bleDeviceName.isEmpty else {
            statusText = "Set a Bluetooth device name in Settings first."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        statusText = "Sending Bluetooth wake pulse to '\(settings.bleDeviceName)'..."
        let woke = await bleWaker.wake(deviceName: settings.bleDeviceName)
        statusText = woke
            ? "Wake pulse sent."
            : "Couldn't find '\(settings.bleDeviceName)' over Bluetooth — is it powered on and nearby?"
        return woke
    }

    /// Runs `operation`; if it fails with a connectivity error (the frame is
    /// likely asleep) and a Bluetooth device name is configured, sends a wake
    /// pulse, polls until the frame answers HTTP again, then retries once.
    func withWakeRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isConnectivityError(error), !settings.bleDeviceName.isEmpty else { throw error }
            statusText = "Frame unreachable — sending Bluetooth wake pulse..."
            guard await bleWaker.wake(deviceName: settings.bleDeviceName) else { throw error }
            statusText = "Wake pulse sent — waiting for frame to come online..."
            guard await waitUntilReachable() else { throw error }
            return try await operation()
        }
    }

    private func waitUntilReachable(maxWait: TimeInterval = 45) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            if (try? await client.fetchDeviceInfo(ip: settings.deviceIP)) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return false
    }

    /// The app and the menu bar widget both poll the frame and both record
    /// readings into the same file, so each re-reads it first: that avoids
    /// writing a reading the other one just stored, and avoids overwriting
    /// the other's newer readings with a stale list.
    private func recordBattery(_ percent: Int?) {
        guard let percent else { return }
        let profileID = settings.activeFrameProfileID
        let stored = BatteryHistory.load(profileID: profileID)
        guard let updated = BatteryHistory.recording(percent, at: Date(), into: stored) else {
            if stored != batterySamples { batterySamples = stored }
            return
        }
        batterySamples = updated
        BatteryHistory.save(updated, profileID: profileID)
    }

    private func applyDeviceInfo(_ info: DeviceInfo) {
        deviceInfo = info
        deviceName = info.name
        // The gallery of the photo actually on screen, read from its path —
        // NOT the frame's own `gallery` field, which is the gallery it last
        // played or uploaded into and was seen saying "Random" while showing
        // a photo from "Favourites". Anything that asks "is a hidden gallery
        // showing?" depends on this being right.
        currentGalleryOnDevice = Self.galleryName(fromDevicePath: info.image) ?? info.gallery
        // Updates the path only, not previewImage/currentImageData — this
        // runs on every 60-second status poll (pollDeviceStatus), not just
        // explicit refresh/send actions, so the "On Frame" highlight in the
        // gallery grid stays accurate even when the display changed for a
        // reason this app process wasn't involved in (the menu bar widget's
        // own auto-random, someone using the widget directly, the frame's
        // own on-device slideshow advancing). Re-fetching the actual image
        // bytes that often would be wasteful, so the big preview thumbnail
        // still only updates on an explicit refresh/send here.
        if let path = info.image, !path.isEmpty {
            setCurrentImagePath(path)
        }
        batteryPercent = info.battery
        recordBattery(info.battery)
        sleepDurationSeconds = info.sleepDuration
        maxIdleSeconds = info.maxIdle
        wakeSensitivity = info.idxWakeSens
        isDeviceAwake = true
        // Keeps rendering sized to whatever frame is actually connected —
        // persisted on `settings` (not just here) so a reasonable size is
        // already known before the first fetch of a future session. Guarded
        // by a change check: this runs on every 60-second status poll, and
        // frameWidth/frameHeight now live inside the active `FrameProfile`,
        // so an unconditional write here would re-encode and persist the
        // *entire* profile (tabs, favorites, everything) every single poll
        // even though a panel's resolution never actually changes at
        // runtime — wasteful for no benefit.
        if let width = info.width, width > 0, width != settings.frameWidth { settings.frameWidth = width }
        if let height = info.height, height > 0, height != settings.frameHeight { settings.frameHeight = height }
    }

    /// Sets `currentImagePath`, clearing `currentLocalSourceURL` unless
    /// `path` turns out to be the same image already showing — used by the
    /// device-truth-sync calls (refresh/redisplay/next/random/etc.), all of
    /// which move to a path with no known local origin, but shouldn't
    /// discard a local origin that's still correct just because the frame
    /// was re-queried.
    /// "/gallerys/Family/1786_P.jpg" → "Family"; nil for anything else.
    public static func galleryName(fromDevicePath path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "gallerys", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    private func setCurrentImagePath(_ path: String) {
        if path != currentImagePath {
            currentLocalSourceURL = nil
        }
        currentImagePath = path
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Re-sends the currently displayed image to the frame. Useful when the
    /// screen visibly didn't update after a previous action — the frame can
    /// silently reject a /show call while it's still mid-draw from an
    /// earlier one, so this retries a few times with a short pause if it
    /// reports busy.
    public func redisplayCurrentPhoto() async {
        guard !settings.deviceIP.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            statusText = "→ GET /deviceInfo"
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)
            statusText = "← /deviceInfo OK"
            guard let path = info.image, !path.isEmpty else {
                statusText = "No current photo to redisplay."
                return
            }

            let maxAttempts = 4
            var lastError: Error?
            for attempt in 1...maxAttempts {
                do {
                    statusText = "→ POST /show?image=\(path)"
                    try await client.show(ip: settings.deviceIP, imagePath: path)
                    statusText = "← /show OK"
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxAttempts {
                        statusText = "← /show BUSY, retrying (\(attempt)/\(maxAttempts))..."
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }
            if let lastError { throw lastError }

            statusText = "→ GET \(path)"
            let data = try await client.fetchImageData(ip: settings.deviceIP, path: path)
            statusText = "← image OK (\(Int(data.count / 1024))KB)"
            previewImage = NSImage(data: data)
            currentImageData = data
            setCurrentImagePath(path)
            statusText = "✓ Redisplayed"
        } catch {
            statusText = "✗ Redisplay failed: \(error.localizedDescription)"
            logActivity("Redisplay failed: \(error.localizedDescription)", success: false)
        }
    }

    /// Advances the frame's current playback queue by one (only meaningful
    /// when it's in gallery-slideshow or playlist mode), then refreshes the
    /// preview to whatever it landed on.
    public func showNextImage() async {
        guard !settings.deviceIP.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry { try await client.showNext(ip: settings.deviceIP) }
            let info = try await client.fetchDeviceInfo(ip: settings.deviceIP)
            applyDeviceInfo(info)
            if let path = info.image, !path.isEmpty {
                let data = try await client.fetchImageData(ip: settings.deviceIP, path: path)
                previewImage = NSImage(data: data)
                currentImageData = data
                setCurrentImagePath(path)
            }
            statusText = "Showed next image."
        } catch {
            statusText = "Couldn't show next image: \(error.localizedDescription)"
            logActivity("Couldn't show next image: \(error.localizedDescription)", success: false)
        }
    }

    /// Starts a gallery slideshow that cycles on-device every `durationSeconds`.
    public func startSlideshow(gallery: String, durationSeconds: Int) async {
        guard !gallery.isEmpty else {
            statusText = "Choose a gallery for the slideshow."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry {
                try await client.startSlideshow(ip: settings.deviceIP, gallery: gallery, durationSeconds: durationSeconds)
            }
            currentGalleryOnDevice = gallery
            statusText = "Started slideshow of '\(gallery)' every \(durationSeconds / 60) min."
            logActivity("Started slideshow of '\(gallery)'", success: true)
        } catch {
            statusText = "Couldn't start slideshow: \(error.localizedDescription)"
            logActivity("Couldn't start slideshow of '\(gallery)': \(error.localizedDescription)", success: false)
        }
    }

    /// Stops slideshow/playlist playback, returning the frame to single-image mode.
    public func stopSlideshow() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry { try await client.stopPlayback(ip: settings.deviceIP) }
            statusText = "Stopped slideshow."
        } catch {
            statusText = "Couldn't stop slideshow: \(error.localizedDescription)"
            logActivity("Couldn't stop slideshow: \(error.localizedDescription)", success: false)
        }
    }

    /// Pushes device-level settings (name, sleep timers, wake sensitivity) to
    /// the frame. Only non-nil values are sent. Refreshes deviceInfo
    /// afterward so the UI reflects what the frame actually accepted.
    public func updateDeviceSettings(name: String?, sleepDurationSeconds: Int?, maxIdleSeconds: Int?, wakeSensitivity: Int?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry {
                try await client.updateSettings(
                    ip: settings.deviceIP,
                    name: name,
                    sleepDuration: sleepDurationSeconds,
                    maxIdle: maxIdleSeconds,
                    idxWakeSens: wakeSensitivity
                )
            }
            let info = try await client.fetchDeviceInfo(ip: settings.deviceIP)
            applyDeviceInfo(info)
            statusText = "Device settings updated."
            logActivity("Device settings updated", success: true)
        } catch {
            statusText = "Couldn't update device settings: \(error.localizedDescription)"
            logActivity("Couldn't update device settings: \(error.localizedDescription)", success: false)
        }
    }

    // MARK: - Frame controls, logging and playlists

    /// Runs a frame command with wake-retry, reporting the outcome in the
    /// status line and the Activity log.
    private func frameCommand(_ done: String, failed: String, _ operation: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry(operation)
            statusText = done
            logActivity(done, success: true)
            return true
        } catch {
            statusText = "\(failed): \(error.localizedDescription)"
            logActivity("\(failed): \(error.localizedDescription)", success: false)
            return false
        }
    }

    public func sleepFrameNow() async {
        if await frameCommand("Frame put to sleep.", failed: "Couldn't put the frame to sleep", { [self] in try await client.sleepNow(ip: settings.deviceIP) }) {
            isDeviceAwake = false
        }
    }

    public func clearFrameScreen() async {
        _ = await frameCommand("Screen cleared to white.", failed: "Couldn't clear the screen", { [self] in try await client.clearScreen(ip: settings.deviceIP) })
    }

    public func rebootFrame() async {
        _ = await frameCommand("Frame is restarting.", failed: "Couldn't restart the frame", { [self] in try await client.reboot(ip: settings.deviceIP) })
    }

    /// What the frame's task processor says it's doing, e.g. "Ready".
    public func fetchTaskStatus() async -> String? {
        guard !settings.deviceIP.isEmpty, let state = try? await client.fetchState(ip: settings.deviceIP) else { return nil }
        return Self.englishTaskStatus(msg: state.msg, code: state.status)
    }

    /// The frame sends its status in Chinese ("就绪") though its docs show
    /// "Ready". Known words are translated; anything else is shown as sent,
    /// with the numeric code, so a new message is at least recognisable.
    static func englishTaskStatus(msg: String?, code: Int?) -> String? {
        let known = ["就绪": "Ready", "忙碌": "Busy", "绘制中": "Drawing", "正在绘制": "Drawing"]
        let trimmed = msg?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let english = known[trimmed] { return english }
        switch (trimmed.isEmpty, code) {
        case (true, nil): return nil
        case (true, let code?): return "Status \(code)"
        case (false, nil): return trimmed
        case (false, let code?): return "\(trimmed) (code \(code))"
        }
    }

    public func fetchLogConfig() async -> BloominClient.LogConfig? {
        guard !settings.deviceIP.isEmpty else { return nil }
        return try? await client.fetchLogConfig(ip: settings.deviceIP)
    }

    public func updateLogConfig(logOn: Bool, keepDays: Int) async -> Bool {
        await frameCommand("Frame logging updated.", failed: "Couldn't update frame logging", { [self] in
            try await client.updateLogConfig(ip: settings.deviceIP, logOn: logOn, keepDays: keepDays)
        })
    }

    public func deleteAllFrameLogs() async -> Bool {
        await frameCommand("Frame logs deleted.", failed: "Couldn't delete the frame's logs", { [self] in try await client.deleteAllLogs(ip: settings.deviceIP) })
    }

    /// Every photo in `gallery` as a full device path, e.g. `/gallerys/Family/x_P.jpg`.
    public func galleryImagePaths(_ gallery: String) async throws -> [String] {
        let names = try await withWakeRetry { try await client.fetchAllImages(ip: settings.deviceIP, gallery: gallery) }
        return names.map { "/gallerys/\(gallery)/\($0)" }
    }

    public func loadPlaylists() async throws -> [BloominClient.PlaylistSummary] {
        try await withWakeRetry { try await client.fetchPlaylists(ip: settings.deviceIP) }
    }

    public func loadPlaylist(_ name: String) async throws -> BloominClient.Playlist {
        try await withWakeRetry { try await client.fetchPlaylist(ip: settings.deviceIP, name: name) }
    }

    public func savePlaylist(name: String, items: [BloominClient.PlaylistItem]) async -> Bool {
        await frameCommand("Saved playlist '\(name)'.", failed: "Couldn't save playlist '\(name)'", { [self] in
            try await client.savePlaylist(ip: settings.deviceIP, name: name, items: items)
        })
    }

    public func deletePlaylist(_ name: String) async -> Bool {
        await frameCommand("Deleted playlist '\(name)'.", failed: "Couldn't delete playlist '\(name)'", { [self] in
            try await client.deletePlaylist(ip: settings.deviceIP, name: name)
        })
    }

    public func playPlaylist(_ name: String) async {
        _ = await frameCommand("Playing playlist '\(name)'.", failed: "Couldn't play playlist '\(name)'", { [self] in
            try await client.playPlaylist(ip: settings.deviceIP, name: name)
        })
    }

    public func refreshCurrentPhoto() async {
        guard !settings.deviceIP.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)
            if let path = info.image, !path.isEmpty {
                let data = try await client.fetchImageData(ip: settings.deviceIP, path: path)
                previewImage = NSImage(data: data)
                currentImageData = data
                setCurrentImagePath(path)
            }
            statusText = ""
        } catch {
            statusText = "Couldn't reach frame: \(error.localizedDescription)"
        }
    }

    /// Displays an image that already lives on the frame, by its device path
    /// (e.g. `/gallerys/Family/IMG_0042.jpg`). The app's gallery browser uses
    /// this to show a specific picked image rather than a random one.
    public func showImageAtPath(_ path: String) async {
        guard !settings.deviceIP.trimmingCharacters(in: .whitespaces).isEmpty else {
            statusText = "Set the frame's IP address first."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry { try await client.show(ip: settings.deviceIP, imagePath: path) }
            setCurrentImagePath(path)
            if let gallery = Self.galleryName(fromDevicePath: path) { currentGalleryOnDevice = gallery }
            statusText = "✓ Displayed \((path as NSString).lastPathComponent)"
            // Best-effort, same reasoning as showRandomPhoto: the send
            // itself already succeeded above, so a failed/slow thumbnail
            // refresh shouldn't be reported as the whole action failing.
            if let data = try? await client.fetchImageData(ip: settings.deviceIP, path: path) {
                previewImage = NSImage(data: data)
                currentImageData = data
            }
        } catch {
            statusText = "✗ Couldn't display that image: \(error.localizedDescription)"
            logActivity("Couldn't display \((path as NSString).lastPathComponent): \(error.localizedDescription)", success: false)
        }
    }

    /// Deletes a single image from a gallery on the device. Returns whether
    /// it succeeded so a caller browsing that gallery can remove it from its
    /// own list without a full reload.
    @discardableResult
    public func deleteDeviceImage(gallery: String, filename: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await withWakeRetry { try await client.deleteImage(ip: settings.deviceIP, filename: filename, gallery: gallery) }
            statusText = "✓ Deleted \(filename)"
            return true
        } catch {
            statusText = "✗ Couldn't delete \(filename): \(error.localizedDescription)"
            logActivity("Couldn't delete \(filename) from '\(gallery)': \(error.localizedDescription)", success: false)
            return false
        }
    }

    /// Moves a single image from one gallery to another on the device.
    /// There's no move endpoint, so this downloads the original bytes,
    /// uploads them unchanged to the destination gallery under the same
    /// filename, and only then deletes the original — a failed upload
    /// leaves the source photo exactly where it was rather than losing it.
    @discardableResult
    public func moveDeviceImage(filename: String, from sourceGallery: String, to destinationGallery: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await withWakeRetry {
                try await client.fetchImageData(ip: settings.deviceIP, path: "/gallerys/\(sourceGallery)/\(filename)")
            }
            await client.ensureGallery(ip: settings.deviceIP, name: destinationGallery)
            _ = try await client.uploadImage(ip: settings.deviceIP, filename: filename, gallery: destinationGallery, imageData: data, showNow: false)
            try await client.deleteImage(ip: settings.deviceIP, filename: filename, gallery: sourceGallery)
            statusText = "✓ Moved \(filename) to '\(destinationGallery)'"
            return true
        } catch {
            statusText = "✗ Couldn't move \(filename): \(error.localizedDescription)"
            logActivity("Couldn't move \(filename) from '\(sourceGallery)' to '\(destinationGallery)': \(error.localizedDescription)", success: false)
            return false
        }
    }

    public func showRandomPhoto() async {
        let galleriesToUse = settings.selectedGalleries.intersection(availableGalleryNames)
        guard !galleriesToUse.isEmpty else {
            statusText = "Select at least one (unlocked) gallery."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            // Cheap reachability probe first: if the frame is asleep, this wakes
            // it over Bluetooth and waits before the (heavier) gallery fetches below.
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)

            let picked: (gallery: String, name: String)
            let statusMessage: String

            switch settings.randomWeighting {
            case .perPhoto:
                // Pool every image from every selected gallery, then pick one photo
                // uniformly from the pool — a gallery with 150 photos naturally
                // contributes more candidates than one with 10.
                var pool: [(gallery: String, name: String)] = []
                for gallery in galleriesToUse {
                    let images = try await client.fetchAllImages(ip: settings.deviceIP, gallery: gallery)
                    pool.append(contentsOf: images.map { (gallery: gallery, name: $0) })
                }
                guard let choice = pool.randomElement() else {
                    statusText = "No images found in the selected galleries."
                    return
                }
                picked = choice
                let galleryWord = galleriesToUse.count == 1 ? "gallery" : "galleries"
                statusMessage = "Picked from \(pool.count) photo\(pool.count == 1 ? "" : "s") across \(galleriesToUse.count) \(galleryWord)."

            case .perGallery:
                // Pick a gallery first, giving every gallery equal odds regardless
                // of size, then a random photo from within just that gallery.
                guard let chosenGallery = galleriesToUse.randomElement() else {
                    statusText = "No images found in the selected galleries."
                    return
                }
                let images = try await client.fetchAllImages(ip: settings.deviceIP, gallery: chosenGallery)
                guard let name = images.randomElement() else {
                    statusText = "No images found in '\(chosenGallery)'."
                    return
                }
                picked = (gallery: chosenGallery, name: name)
                statusMessage = "Picked gallery '\(chosenGallery)' (\(images.count) photos), then a random photo from it."
            }

            let path = "/gallerys/\(picked.gallery)/\(picked.name)"
            try await withWakeRetry { try await client.show(ip: settings.deviceIP, imagePath: path) }
            setCurrentImagePath(path)
            currentGalleryOnDevice = picked.gallery
            statusText = statusMessage
            // Refreshing the local preview thumbnail is best-effort — the
            // send itself already succeeded above, so a slow or failed
            // fetch here shouldn't get reported as the whole action having
            // failed (it previously did, which meant a photo that had
            // already sent successfully could still show as an error,
            // prompting a redundant retry).
            if let data = try? await client.fetchImageData(ip: settings.deviceIP, path: path) {
                previewImage = NSImage(data: data)
                currentImageData = data
            }
        } catch {
            statusText = "Couldn't show a random photo: \(error.localizedDescription)"
            logActivity("Couldn't show a random photo: \(error.localizedDescription)", success: false)
        }
    }

    public struct RandomPhotoCandidate: Identifiable {
        public let id = UUID()
        public let devicePath: String
        public let gallery: String
        public let image: NSImage
    }

    /// Multiple randomly-picked device photos for the user to choose from.
    /// Set by `prepareRandomPhotoCandidates()`, cleared by
    /// `cancelRandomPhotoCandidates()`.
    @Published public var randomPhotoCandidates: [RandomPhotoCandidate] = []

    /// Picks 3 random photos from the selected galleries — respecting
    /// `settings.randomWeighting`, same as `showRandomPhoto` — and renders
    /// them for the user to pick one from, instead of `showRandomPhoto`'s
    /// "send the first pick immediately" behavior. Kept as its own function
    /// rather than adding a picker mode to `showRandomPhoto` itself: that
    /// one is also what the unattended auto-random timer calls, and
    /// shouldn't change shape or its exact status-message wording.
    public func prepareRandomPhotoCandidates() async {
        let galleriesToUse = settings.selectedGalleries.intersection(availableGalleryNames)
        guard !galleriesToUse.isEmpty else {
            statusText = "Select at least one (unlocked) gallery."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)

            // Caches each gallery's listing for the duration of this one
            // call only, so picking 3 candidates that happen to land in the
            // same gallery (likely with `.perGallery` weighting and few
            // galleries selected) doesn't re-fetch its listing 3 times.
            var listingCache: [String: [String]] = [:]
            func images(in gallery: String) async throws -> [String] {
                if let cached = listingCache[gallery] { return cached }
                let images = try await client.fetchAllImages(ip: settings.deviceIP, gallery: gallery)
                listingCache[gallery] = images
                return images
            }

            var picks: [(gallery: String, name: String)] = []
            switch settings.randomWeighting {
            case .perPhoto:
                var pool: [(gallery: String, name: String)] = []
                for gallery in galleriesToUse {
                    let names = try await images(in: gallery)
                    pool.append(contentsOf: names.map { (gallery: gallery, name: $0) })
                }
                guard !pool.isEmpty else {
                    statusText = "No images found in the selected galleries."
                    return
                }
                picks = (0..<3).compactMap { _ in pool.randomElement() }
            case .perGallery:
                for _ in 0..<3 {
                    guard let chosenGallery = galleriesToUse.randomElement() else { continue }
                    let names = try await images(in: chosenGallery)
                    guard let name = names.randomElement() else { continue }
                    picks.append((gallery: chosenGallery, name: name))
                }
                guard !picks.isEmpty else {
                    statusText = "No images found in the selected galleries."
                    return
                }
            }

            var candidates: [RandomPhotoCandidate] = []
            for pick in picks {
                let path = "/gallerys/\(pick.gallery)/\(pick.name)"
                guard let data = try? await client.fetchImageData(ip: settings.deviceIP, path: path),
                      let image = NSImage(data: data)
                else { continue }
                candidates.append(RandomPhotoCandidate(devicePath: path, gallery: pick.gallery, image: image))
            }
            guard !candidates.isEmpty else {
                statusText = "Couldn't load any of the picked photos."
                return
            }
            randomPhotoCandidates = candidates
            statusText = ""
        } catch {
            statusText = "Couldn't pick random photos: \(error.localizedDescription)"
            logActivity("Couldn't pick random photos: \(error.localizedDescription)", success: false)
        }
    }

    /// Discards pending random-photo candidates without displaying anything.
    public func cancelRandomPhotoCandidates() {
        randomPhotoCandidates = []
    }

    /// Generates a fresh image from one of the checked content sources
    /// (chosen at random if more than one is checked), uploads it to that
    /// source's own gallery (matching whatever the original Python scripts
    /// already used, e.g. "NASA" for APOD), and displays it immediately.
    public func showRandomGeneratedContent() async {
        let sources = ContentSources.all.filter { settings.selectedContentSources.contains($0.id) }
        guard let source = sources.randomElement() else {
            statusText = "Select at least one content source."
            return
        }
        await showGeneratedContent(from: source)
    }

    /// Runs a scheduled content entry now (also the "Run Now" button in
    /// Settings): generates from its source — today's item where it has one
    /// and the schedule asks for it — then uploads and displays it.
    public func fireScheduledContent(_ schedule: ScheduledContent) async {
        guard let source = ContentSources.all.first(where: { $0.id == schedule.sourceID }) else {
            statusText = "Scheduled content: that source no longer exists."
            logActivity("Scheduled content: unknown source '\(schedule.sourceID)'", success: false)
            return
        }
        await showGeneratedContent(from: source, today: schedule.useToday)
    }

    private func showGeneratedContent(from source: ContentSource, today: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)

            statusText = "Generating \(source.displayName)..."
            let usesToday = today && source is TodayContentSource
            let generated: GeneratedContent
            if usesToday, let todaySource = source as? TodayContentSource {
                generated = try await todaySource.generateTodayImageAndCard(settings: settings)
            } else {
                generated = try await source.generateImageAndCard(settings: settings)
            }
            let imageData = generated.data

            await client.ensureGallery(ip: settings.deviceIP, name: source.galleryName)
            // Today's item is named by date, so running it twice in a day
            // replaces that day's copy instead of adding another.
            let stamp: String
            if usesToday {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                stamp = "today_\(formatter.string(from: Date()))"
            } else {
                stamp = String(Int(Date().timeIntervalSince1970))
            }
            let filename = orientedFilename("\(source.id)_\(stamp)")
            let path = try await client.uploadImage(
                ip: settings.deviceIP,
                filename: filename,
                gallery: source.galleryName,
                imageData: imageData,
                showNow: true
            )

            previewImage = NSImage(data: imageData)
            currentImageData = imageData
            setCurrentImagePath(path)
            currentGalleryOnDevice = source.galleryName
            // The picture's museum card (NASA's title, date, credit and
            // description), filed under where it now lives on the frame.
            // This is the path the Today's NASA button, the scheduled send and
            // Generate & Display all take; the picker route files its own.
            if let card = generated.card {
                MuseumCardStore.shared.autoFill(card, for: path)
            }
            statusText = "Showed \(source.displayName)."
            logActivity("Showed \(source.displayName)", success: true)

            // Pick up the source's gallery in the picker in case it's new.
            await loadGalleries()
        } catch {
            statusText = "Couldn't generate \(source.displayName): \(error.localizedDescription)"
            logActivity("Couldn't generate \(source.displayName): \(error.localizedDescription)", success: false)
        }
    }


    /// The frame's firmware requires uploaded filenames to end with `_P.jpg`
    /// (portrait) or `_L.jpg` (landscape — the device rotates the stored
    /// pixels 90° at display time); a missing suffix corrupts the display
    /// (see Schedule_Pull_API.md §5.3). Matches `settings.frameOrientation`,
    /// which is also what decided the canvas this image was actually
    /// rendered onto (`settings.renderWidth`/`renderHeight`) — the two have
    /// to agree, or the frame rotates pixels that were never composed for
    /// rotation.
    func orientedFilename(_ base: String) -> String {
        let suffix = settings.frameOrientation == .landscape ? "L" : "P"
        return "\(base)_\(suffix).jpg"
    }

    /// Strips anything that isn't a plain ASCII letter/digit/underscore/
    /// hyphen out of a filename component before it becomes part of an
    /// upload filename. A local file's real name can contain spaces,
    /// apostrophes, parentheses, unicode, commas, and other characters the
    /// frame's firmware doesn't accept in `/upload`'s `filename` parameter
    /// — confirmed directly against the device: it logs "Invalid filename
    /// or extension" and rejects the whole upload outright, before ever
    /// logging what was actually attempted. Photos-library candidates
    /// already sanitized their (human-readable date, not a real filename)
    /// name for the same reason; this brings every other source in line.
    private func sanitizeFilenameComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
    }

    /// Fits `cgImage` onto a `width`x`height` portrait canvas, choosing
    /// aspect-fill (crop and center, no bars) over aspect-fit (whole photo
    /// visible, letterboxed) only when both `cropLandscapePhotos` is true and
    /// the source is actually landscape. A portrait or square source already
    /// roughly matches the frame's aspect ratio and doesn't have the "tiny
    /// photo between two black bars" problem the setting exists to fix, so
    /// it's always fit rather than cropped regardless of the flag.
    ///
    /// `nonisolated` and takes the flag as a plain parameter rather than
    /// reading `settings.cropLandscapePhotos` itself: one call site runs
    /// inside `Task.detached` off the main actor, so this can't be
    /// `@MainActor`-isolated the way an ordinary instance method would be by
    /// default.
    nonisolated func renderForFrame(cgImage: CGImage, width: Int, height: Int, cropLandscapePhotos: Bool) -> NSImage? {
        // Tuned before framing, so the black letterbox bars aren't pushed
        // around by the contrast/brightness adjustments. A no-op by default.
        let source = EInkTuner.apply(EInkTuning.stored(), to: cgImage)
        let isLandscape = source.width > source.height
        if cropLandscapePhotos, isLandscape {
            return renderFilled(cgImage: source, width: width, height: height)
        }
        return renderLetterboxed(cgImage: source, width: width, height: height, background: .black)
    }


    public struct LocalFolderCandidate {
        public let fileURL: URL
        public let image: NSImage
        public let jpegData: Data
        /// The device gallery this gets uploaded into on confirm. Local
        /// Folder/video-frame candidates go to "Random"; Photos-library
        /// candidates go to their own "Apple" gallery instead, so the two
        /// sources don't mix in the same place on the frame.
        public let gallery: String
        /// Whether `fileURL` is a real file on disk — true for Local
        /// Folder/video candidates, false for Photos-library candidates
        /// (whose `fileURL` is a synthetic, non-existent path built only to
        /// derive an upload filename — see `preparePhotosLibraryImage`).
        /// Determines whether `confirmLocalFolderCandidate` can offer
        /// favoriting afterward, since Favorites is a bookmark list of real
        /// local files everywhere else in the app.
        public let isLocalFile: Bool
        /// A short stable fingerprint of what this candidate was rendered
        /// from (source file/asset + the settings that change its render),
        /// or nil when there's nothing stable to fingerprint (a generated
        /// image, a random video frame). Lets `confirmLocalFolderCandidate`
        /// name the upload deterministically and, if that exact file is
        /// already on the frame, just display it instead of uploading a
        /// second copy.
        public var sourceKey: String? = nil
        /// Metadata for the museum card, for candidates whose `fileURL`
        /// isn't a real file to read it from (Photos-library images).
        public var sourceMetadata: PhotoMetadata? = nil
        /// A ready-made museum card, for generated pictures whose source
        /// knows what they are (NASA's picture of the day).
        public var museumCard: MuseumCard? = nil
    }

    /// `path|modified|size|crop|WxH` for a local file, hashed to 8 hex chars.
    /// Changes when the file is edited or when a setting that changes how it
    /// renders changes (crop, canvas size/orientation) — either way the old
    /// copy on the frame is no longer the right thing to show. `nonisolated`
    /// so the background render task can call it.
    nonisolated private static func sourceKey(forFile url: URL, cropLandscapePhotos: Bool, width: Int, height: Int, crop: CropRegion? = nil) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var text = "\(url.path)|\(modified)|\(size)|\(cropLandscapePhotos)|\(width)x\(height)" + EInkTuning.stored().fingerprint
        // Appended only for an explicit crop, so photos sent without one keep
        // exactly the key (and so the on-frame filename) they always had.
        if let crop { text += "|crop:\(crop.keyDescription)" }
        return shortHash(text)
    }

    nonisolated static func sourceKey(forPhotosAsset id: String, cropLandscapePhotos: Bool, width: Int, height: Int) -> String {
        shortHash("photos|\(id)|\(cropLandscapePhotos)|\(width)x\(height)" + EInkTuning.stored().fingerprint)
    }

    nonisolated private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Multiple randomly-picked candidates for the user to choose from.
    /// Set by `prepareLocalFolderCandidate()`, cleared by `cancelLocalFolderCandidate()`.
    @Published public var localFolderCandidates: [LocalFolderCandidate] = []

    /// Picks 3 random images from the local folder, renders them for preview on
    /// a background thread, and presents them for the user to choose from.
    public func prepareLocalFolderCandidate() {
        let folderPath = settings.randomFolderPath.trimmingCharacters(in: .whitespaces)
        guard !folderPath.isEmpty else {
            statusText = "Choose a folder to pick random photos from."
            return
        }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let allImages = ImageFolder.enumerateImages(in: folderURL)
        guard allImages.count >= 1 else {
            statusText = "No photos found in '\(folderURL.lastPathComponent)'."
            return
        }
        renderRandomCandidates(from: allImages, unreadableMessage: "Couldn't read any photos from '\(folderURL.lastPathComponent)'.")
    }

    /// Same 3-candidate preview as `prepareLocalFolderCandidate`, but drawn
    /// recursively from an arbitrary folder — the Browse Files tab's "Random
    /// from Here", which can be any subfolder you've navigated into rather
    /// than only the one fixed Local Folder path.
    public func prepareCandidate(fromFolder folderURL: URL) {
        let allImages = ImageFolder.enumerateImages(in: folderURL)
        guard allImages.count >= 1 else {
            statusText = "No photos found in '\(folderURL.lastPathComponent)'."
            return
        }
        renderRandomCandidates(from: allImages, unreadableMessage: "Couldn't read any photos from '\(folderURL.lastPathComponent)'.")
    }

    /// Same 3-candidate preview as `prepareLocalFolderCandidate`, but drawn
    /// from the Favourites list instead of the whole Local Folder. Favourites
    /// are plain file paths that may point at an external volume that isn't
    /// mounted right now, so missing files are filtered out up front.
    public func prepareFavoritesCandidate() {
        let existing = settings.favoriteImagePaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !existing.isEmpty else {
            statusText = settings.favoriteImagePaths.isEmpty
                ? "No favourites yet."
                : "None of your favourites could be found — is the drive they live on connected?"
            return
        }
        renderRandomCandidates(from: existing, unreadableMessage: "Couldn't read any of your favourites.")
    }

    /// Picks up to 3 of `urls` at random, renders them for the frame off the
    /// main thread, and publishes them as `localFolderCandidates`.
    private func renderRandomCandidates(from urls: [URL], unreadableMessage: String) {
        let cropLandscapePhotos = settings.cropLandscapePhotos
        let renderWidth = settings.renderWidth
        let renderHeight = settings.renderHeight

        Task.detached(priority: .userInitiated) { [weak self] in
            var candidates: [LocalFolderCandidate] = []
            let chosenURLs = urls.shuffled().prefix(min(3, urls.count))

            for chosen in chosenURLs {
                guard let cgImage = loadUprightCGImage(at: chosen),
                      let framed = self?.renderForFrame(cgImage: cgImage, width: renderWidth, height: renderHeight, cropLandscapePhotos: cropLandscapePhotos),
                      let jpeg = ImageCanvas.jpegData(framed)
                else {
                    continue
                }
                var candidate = LocalFolderCandidate(fileURL: chosen, image: framed, jpegData: jpeg, gallery: "Random", isLocalFile: true)
                candidate.sourceKey = Self.sourceKey(forFile: chosen, cropLandscapePhotos: cropLandscapePhotos, width: renderWidth, height: renderHeight)
                candidates.append(candidate)
            }

            await MainActor.run {
                guard !candidates.isEmpty else {
                    self?.statusText = unreadableMessage
                    return
                }

                self?.localFolderCandidates = candidates
                self?.statusText = ""
            }
        }
    }

    /// Discards all pending candidates without uploading anything.
    public func cancelLocalFolderCandidate() {
        localFolderCandidates = []
    }

    /// Fetches 3 random renders from any `ContentSource` and presents them
    /// as candidates, same "look at a few, Next for more, confirm before
    /// sending" pattern as `prepareLocalFolderCandidate` — worth it for a
    /// source whose output varies a lot per call (APOD's genuinely random
    /// day from the whole archive, Fortune's random quote+style), where
    /// `showRandomGeneratedContent`'s one-shot generate-and-display never
    /// let you see what you'd get before it was already on the frame.
    /// Sequential, not concurrent: APOD's public NASA key is already
    /// rate-limited, and each source's own `generateImage` already retries
    /// internally where that makes sense (APOD skips video-only dates), so
    /// 3 fetches back to back is enough load already.
    public func prepareContentCandidates(source: ContentSource) async {
        statusText = "Generating \(source.displayName) options…"
        var candidates: [LocalFolderCandidate] = []
        for index in 0..<3 {
            guard let generated = try? await source.generateImageAndCard(settings: settings),
                  let image = NSImage(data: generated.data)
            else { continue }
            let jpeg = generated.data
            let name = "\(source.id)_\(Int(Date().timeIntervalSince1970 * 1000))_\(index)"
            var candidate = LocalFolderCandidate(fileURL: URL(fileURLWithPath: name), image: image, jpegData: jpeg, gallery: source.galleryName, isLocalFile: false)
            candidate.museumCard = generated.card
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else {
            statusText = "Couldn't generate any \(source.displayName) options right now."
            return
        }
        localFolderCandidates = candidates
        statusText = ""
    }

    /// Replaces the pending candidates with just `source`'s "today" item (for
    /// APOD, the actual picture of the day). Returns an error message if it
    /// couldn't be fetched, leaving the existing candidates untouched.
    public func prepareTodayCandidate(source: TodayContentSource) async -> String? {
        do {
            let generated = try await source.generateTodayImageAndCard(settings: settings)
            let jpeg = generated.data
            guard let image = NSImage(data: jpeg) else {
                return "Couldn't read today's \(source.displayName)."
            }
            let name = "\(source.id)_today_\(Int(Date().timeIntervalSince1970 * 1000))"
            var candidate = LocalFolderCandidate(fileURL: URL(fileURLWithPath: name), image: image, jpegData: jpeg, gallery: source.galleryName, isLocalFile: false)
            candidate.museumCard = generated.card
            localFolderCandidates = [candidate]
            statusText = ""
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Picks one random item — image or video — from the whole Local Folder
    /// and sends it straight to the frame, no picker step. Unlike
    /// `prepareLocalFolderCandidate` (three image candidates for the user to
    /// choose from) this is meant as a single "surprise me" button covering
    /// everything in the folder, videos included: a picked video gets a
    /// frame grabbed automatically at a random point rather than opening
    /// `VideoFramePickerSheet` — that sheet is still there for when someone
    /// wants to choose the video's frame deliberately, by tapping it in the
    /// grid.
    public func randomFromLocalFolder() async {
        let folderPath = settings.randomFolderPath.trimmingCharacters(in: .whitespaces)
        guard !folderPath.isEmpty else {
            statusText = "Choose a Local Folder first."
            return
        }
        // Same gate as browsing Local Folder itself — this button reaches
        // the same content from the Frame pane, so it shouldn't offer a
        // side door around the lock just because it lives elsewhere in the UI.
        guard !settings.localFolderLocked || isLocalFolderUnlocked else {
            statusText = "Local Folder is locked."
            return
        }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        statusText = "Picking a random file…"
        let (imageURLs, videoURLs) = await Task.detached(priority: .userInitiated) {
            (ImageFolder.enumerateImages(in: folderURL), VideoFolder.enumerateVideos(in: folderURL))
        }.value

        enum Pick { case image(URL), video(URL) }
        let pool: [Pick] = imageURLs.map { .image($0) } + videoURLs.map { .video($0) }
        guard let picked = pool.randomElement() else {
            statusText = "No photos or videos found in '\(folderURL.lastPathComponent)'."
            return
        }

        switch picked {
        case .image(let url):
            prepareBrowsedImage(url: url)
        case .video(let url):
            guard let frame = await VideoFrameExtractor.randomFrame(from: url),
                  let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                statusText = "Couldn't grab a frame from '\(url.lastPathComponent)'."
                return
            }
            prepareVideoFrame(cgImage: cgImage, sourceURL: url)
        }

        guard let candidate = localFolderCandidates.first else { return }
        await confirmLocalFolderCandidate(candidate)
        cancelLocalFolderCandidate()
    }

    /// True if the image currently on the frame belongs to a gallery that
    /// counts as hidden — a gallery tab with a password set (checked
    /// regardless of any in-session unlock, since a background schedule
    /// check isn't a "session" in that sense), or the "Random" gallery
    /// (every Local Folder/Favorites/video-frame upload's fixed destination
    /// — see `LocalFolderCandidate.gallery`), which is always treated as
    /// hidden here regardless of whether the separate Local Folder password
    /// is currently on — anything landing in Random came from this Mac's
    /// own files, not frame content, so a scheduled revert should always be
    /// willing to cover for it. Checked against `currentGalleryOnDevice` —
    /// device truth refreshed from `/deviceInfo` — rather than
    /// `currentLocalSourceURL`, which only reflects this session's most
    /// recent upload and goes nil the instant anything else is redisplayed,
    /// even a re-display of that same hidden photo. Used by the
    /// scheduled-send safety net to decide whether reverting is warranted.
    public var isCurrentlyDisplayingHiddenGallery: Bool {
        guard let currentGalleryOnDevice else { return false }
        if currentGalleryOnDevice == "Random" {
            return true
        }
        return settings.lockedTab(for: currentGalleryOnDevice, unlockedTabIDs: []) != nil
    }

    /// Re-displays `schedule`'s photo (already on the frame) right now,
    /// honoring its `requireHiddenGalleryDisplayed` condition. Called by the
    /// App target's own timer at the schedule's configured time — reuses
    /// `showImageAtPath`, the same "show this exact device photo" pipeline a
    /// gallery-grid tap on an already-uploaded item goes through, since
    /// nothing needs to be re-uploaded here.
    public func fireScheduledSend(_ schedule: ScheduledSend) async {
        guard !schedule.devicePath.isEmpty else {
            statusText = "Scheduled send has no photo chosen."
            return
        }
        if schedule.requireHiddenGalleryDisplayed {
            // Ask the frame what it is showing right now. The answer the app
            // last heard can be hours old — the frame is asleep most of the
            // day and photos get switched by hand, from the phone app, etc.
            do {
                let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
                applyDeviceInfo(info)
            } catch {
                statusText = "Scheduled send skipped: couldn't reach the frame to see what it's showing."
                logActivity("Scheduled send skipped — couldn't reach the frame to check what it's showing", success: false)
                return
            }
            guard isCurrentlyDisplayingHiddenGallery else {
                let gallery = currentGalleryOnDevice ?? "an unknown gallery"
                statusText = "Scheduled send skipped: the frame is showing a photo from \u{2018}\(gallery)\u{2019}, which isn't hidden."
                logActivity("Scheduled send skipped — the frame is showing a photo from '\(gallery)', which isn't hidden", success: true)
                return
            }
        }
        await showImageAtPath(schedule.devicePath)
        if currentImagePath == schedule.devicePath {
            logActivity("Scheduled send: showed \((schedule.devicePath as NSString).lastPathComponent)", success: true)
        }
    }

    /// Loads and prepares a specific image from a file path for display/upload.
    public func prepareBrowsedImage(url: URL) {
        guard let cgImage = loadUprightCGImage(at: url),
              let framed = renderForFrame(cgImage: cgImage, width: settings.renderWidth, height: settings.renderHeight, cropLandscapePhotos: settings.cropLandscapePhotos),
              let jpeg = ImageCanvas.jpegData(framed)
        else {
            statusText = "Couldn't read '\(url.lastPathComponent)'."
            return
        }
        var candidate = LocalFolderCandidate(fileURL: url, image: framed, jpegData: jpeg, gallery: "Random", isLocalFile: true)
        candidate.sourceKey = Self.sourceKey(forFile: url, cropLandscapePhotos: settings.cropLandscapePhotos, width: settings.renderWidth, height: settings.renderHeight)
        localFolderCandidates = [candidate]
        statusText = ""
    }

    /// Same as `prepareBrowsedImage`, but for a frame already extracted from
    /// a local video (`VideoFrameExtractor`) rather than a still image on
    /// disk — `sourceURL` is kept only for display/reveal-in-Finder, the
    /// frame itself comes from `cgImage`, not from re-reading that file.
    public func prepareVideoFrame(cgImage: CGImage, sourceURL: URL) {
        guard let framed = renderForFrame(cgImage: cgImage, width: settings.renderWidth, height: settings.renderHeight, cropLandscapePhotos: settings.cropLandscapePhotos),
              let jpeg = ImageCanvas.jpegData(framed)
        else {
            statusText = "Couldn't process that frame."
            return
        }
        localFolderCandidates = [LocalFolderCandidate(fileURL: sourceURL, image: framed, jpegData: jpeg, gallery: "Random", isLocalFile: true)]
        statusText = ""
    }

    /// Same as `prepareBrowsedImage`, but for an image exported from the
    /// Photos library rather than read from a file on disk — `displayName`
    /// (e.g. "Aug 21, 2026, 3:45 PM", since Photos assets don't reliably
    /// expose a real filename) is only used to build the uploaded filename,
    /// sanitized first since `confirmLocalFolderCandidate` uses it verbatim
    /// and the frame's upload endpoint shouldn't have to deal with commas,
    /// colons, or spaces in a filename.
    public func preparePhotosLibraryImage(data: Data, displayName: String, assetID: String? = nil) {
        guard let cgImage = loadUprightCGImage(data: data),
              let framed = renderForFrame(cgImage: cgImage, width: settings.renderWidth, height: settings.renderHeight, cropLandscapePhotos: settings.cropLandscapePhotos),
              let jpeg = ImageCanvas.jpegData(framed)
        else {
            statusText = "Couldn't process that photo."
            return
        }
        let safeName = sanitizeFilenameComponent(displayName)
        var candidate = LocalFolderCandidate(fileURL: URL(fileURLWithPath: safeName), image: framed, jpegData: jpeg, gallery: "Apple", isLocalFile: false)
        candidate.sourceMetadata = PhotoMetadata.read(from: data)
        if let assetID {
            candidate.sourceKey = Self.sourceKey(forPhotosAsset: assetID, cropLandscapePhotos: settings.cropLandscapePhotos, width: settings.renderWidth, height: settings.renderHeight)
        }
        localFolderCandidates = [candidate]
        statusText = ""
    }

    /// Several Photos-library images at once (the Random-from-an-album and
    /// "on this day" pickers): renders each for the frame off the main thread
    /// and publishes them as `localFolderCandidates`, like the folder pickers do.
    public func preparePhotosCandidates(_ items: [(data: Data, displayName: String, assetID: String)]) async {
        let width = settings.renderWidth
        let height = settings.renderHeight
        let crop = settings.cropLandscapePhotos
        let rendered: [(image: NSImage, jpeg: Data, displayName: String, assetID: String, metadata: PhotoMetadata?)] = await Task.detached(priority: .userInitiated) { [weak self] in
            items.compactMap { item in
                guard let cgImage = loadUprightCGImage(data: item.data),
                      let framed = self?.renderForFrame(cgImage: cgImage, width: width, height: height, cropLandscapePhotos: crop),
                      let jpeg = ImageCanvas.jpegData(framed)
                else { return nil }
                return (framed, jpeg, item.displayName, item.assetID, PhotoMetadata.read(from: item.data))
            }
        }.value

        var candidates: [LocalFolderCandidate] = []
        for item in rendered {
            var candidate = LocalFolderCandidate(
                fileURL: URL(fileURLWithPath: sanitizeFilenameComponent(item.displayName)),
                image: item.image, jpegData: item.jpeg, gallery: "Apple", isLocalFile: false
            )
            candidate.sourceKey = Self.sourceKey(forPhotosAsset: item.assetID, cropLandscapePhotos: crop, width: width, height: height)
            candidate.sourceMetadata = item.metadata
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else {
            statusText = "Couldn't process those photos."
            return
        }
        localFolderCandidates = candidates
        statusText = ""
    }

    /// Whether `candidate` was rendered from a still image file on disk that
    /// can be re-rendered with a chosen crop. False for generated images,
    /// Photos-library items and video frames, which have no such file.
    public func canCrop(_ candidate: LocalFolderCandidate) -> Bool {
        candidate.isLocalFile
            && ImageFolder.imageFileExtensions.contains(candidate.fileURL.pathExtension.lowercased())
            && FileManager.default.fileExists(atPath: candidate.fileURL.path)
    }

    /// `candidate` re-rendered from its source file with `crop` instead of
    /// the default fit, ready to confirm. Its `sourceKey` includes the crop,
    /// so a differently-cropped copy of the same photo is a different file
    /// on the frame rather than being mistaken for one already uploaded.
    public func cropped(_ candidate: LocalFolderCandidate, crop: CropRegion) -> LocalFolderCandidate? {
        guard canCrop(candidate),
              let cgImage = loadUprightCGImage(at: candidate.fileURL),
              let image = renderCropped(cgImage: EInkTuner.apply(EInkTuning.stored(), to: cgImage), crop: crop, width: settings.renderWidth, height: settings.renderHeight),
              let jpeg = ImageCanvas.jpegData(image)
        else {
            statusText = "Couldn't crop '\(candidate.fileURL.lastPathComponent)'."
            return nil
        }
        var result = LocalFolderCandidate(fileURL: candidate.fileURL, image: image, jpegData: jpeg, gallery: candidate.gallery, isLocalFile: true)
        result.sourceKey = Self.sourceKey(forFile: candidate.fileURL, cropLandscapePhotos: settings.cropLandscapePhotos, width: settings.renderWidth, height: settings.renderHeight, crop: crop)
        return result
    }

    /// Prepares `fileURL` normally, applies `crop`, and sends the result.
    public func sendCropped(fileURL: URL, crop: CropRegion) async {
        prepareBrowsedImage(url: fileURL)
        guard let base = localFolderCandidates.first, let candidate = cropped(base, crop: crop) else { return }
        await confirmLocalFolderCandidate(candidate)
        cancelLocalFolderCandidate()
    }

    /// Uploads the approved candidate to its `gallery` and displays it
    /// immediately.
    public func confirmLocalFolderCandidate(_ candidate: LocalFolderCandidate) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let gallery = candidate.gallery
            let sourceBase = sanitizeFilenameComponent(candidate.fileURL.deletingPathExtension().lastPathComponent)
            let fileSizeKB = Int(candidate.jpegData.count / 1024)
            // A candidate with a `sourceKey` gets a deterministic name (same
            // photo + same render settings = same filename) instead of a
            // timestamp, so sending it again finds the copy already on the
            // frame rather than uploading another one. Uploads to this frame
            // take 10-40s, so displaying what's already there is also much
            // faster.
            let filename: String
            if let key = candidate.sourceKey {
                filename = orientedFilename("\(sourceBase)-\(key)")
                let existingPath = "/gallerys/\(gallery)/\(filename)"
                statusText = "Checking whether it's already on the frame…"
                if await client.imageExists(ip: settings.deviceIP, path: existingPath) {
                    do {
                        try await withWakeRetry { try await client.show(ip: settings.deviceIP, imagePath: existingPath) }
                        previewImage = candidate.image
                        currentImageData = candidate.jpegData
                        currentImagePath = existingPath
                        currentLocalSourceURL = candidate.isLocalFile ? candidate.fileURL : nil
                        currentGalleryOnDevice = gallery
                        fillMuseumCard(for: existingPath, candidate: candidate)
                        statusText = "✓ Already on the frame — displayed \(filename) without uploading again"
                        logActivity("Displayed \(filename) — already on the frame", success: true)
                        localFolderCandidates = []
                        return
                    } catch {
                        // Couldn't show the existing copy (deleted since the
                        // check, frame busy) — fall through to a normal upload.
                    }
                }
            } else {
                filename = orientedFilename("\(sourceBase)_\(Int(Date().timeIntervalSince1970))")
            }

            // No separate up-front `/deviceInfo` probe: it isn't required
            // for the upload to succeed, it's just one more round-trip to a
            // frame whose embedded server already struggles with
            // back-to-back requests. `withWakeRetry` wraps the *whole*
            // ensure-gallery-then-upload attempt sequence below instead —
            // and only escalates to a Bluetooth wake pulse if every one of
            // its ordinary retries has already failed, since most timeouts
            // here are the server being briefly busy, not the frame
            // actually asleep, and a wake-and-wait cycle is much slower
            // than just trying again.
            let path = try await withWakeRetry {
                try await self.uploadWithRetries(gallery: gallery, filename: filename, imageData: candidate.jpegData, fileSizeKB: fileSizeKB)
            }

            previewImage = candidate.image
            currentImageData = candidate.jpegData
            currentImagePath = path
            currentLocalSourceURL = candidate.isLocalFile ? candidate.fileURL : nil
            currentGalleryOnDevice = gallery
            fillMuseumCard(for: path, candidate: candidate)
            statusText = "← /upload OK\n✓ Displayed \(filename)"
            logActivity("Uploaded and displayed \(filename)", success: true)

            localFolderCandidates = []
            await loadGalleries()
        } catch {
            statusText = "✗ Upload error: \(error.localizedDescription)\n(File: \(candidate.fileURL.lastPathComponent))"
            logActivity("Couldn't upload \(candidate.fileURL.lastPathComponent): \(error.localizedDescription)", success: false)
        }
    }

    /// Where a candidate's museum-card metadata comes from: the file itself
    /// for local photos, or what was captured when a Photos-library image
    /// was prepared.
    /// Files the candidate's museum card under its path on the frame: the
    /// ready-made card a generated picture came with, or one built from the
    /// photo's own metadata.
    private func fillMuseumCard(for path: String, candidate: LocalFolderCandidate) {
        if let card = candidate.museumCard {
            MuseumCardStore.shared.autoFill(card, for: path)
        } else {
            MuseumCardStore.shared.autoFill(path: path, metadata: cardMetadata(for: candidate))
        }
    }

    private func cardMetadata(for candidate: LocalFolderCandidate) -> PhotoMetadata? {
        candidate.isLocalFile ? PhotoMetadata.read(from: candidate.fileURL) : candidate.sourceMetadata
    }

    /// Ensures `gallery` exists and uploads `imageData` to it, retrying the
    /// upload itself up to 3 times with a short backoff — handles the
    /// frame's embedded server being briefly busy without escalating to a
    /// Bluetooth wake pulse for what's usually just a transient timeout.
    /// The caller (`withWakeRetry`) only reaches for the wake pulse if every
    /// attempt here still fails.
    private func uploadWithRetries(gallery: String, filename: String, imageData: Data, fileSizeKB: Int) async throws -> String {
        statusText = "→ PUT /gallery?name=\(gallery)"
        await client.ensureGallery(ip: settings.deviceIP, name: gallery)
        statusText = "← /gallery OK"

        var lastError: Error = BloominError.badResponse("Upload failed after 3 attempts")
        for attempt in 1...3 {
            do {
                statusText = "→ POST /upload?filename=\(filename)&gallery=\(gallery)&show_now=1\n📦 \(fileSizeKB)KB [Attempt \(attempt)/3]"
                return try await client.uploadImage(ip: settings.deviceIP, filename: filename, gallery: gallery, imageData: imageData, showNow: true)
            } catch {
                lastError = error
                statusText = "← /upload failed (attempt \(attempt)/3): \(error.localizedDescription)"
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) // Wait 1-2 seconds before retry
                }
            }
        }
        throw lastError
    }

    /// Deletes the entire Random gallery from the device.
    public func deleteRandomGallery() async {
        isBusy = true
        defer { isBusy = false }
        do {
            statusText = "→ GET /deviceInfo"
            let info = try await withWakeRetry { try await client.fetchDeviceInfo(ip: settings.deviceIP) }
            applyDeviceInfo(info)
            statusText = "← /deviceInfo OK"

            let gallery = "Random"
            statusText = "→ DELETE /gallery?name=\(gallery)"
            try await client.deleteGallery(ip: settings.deviceIP, name: gallery)
            statusText = "← /gallery OK"

            statusText = "✓ Deleted Random gallery"
            logActivity("Deleted the Random gallery", success: true)
            await loadGalleries()
        } catch {
            statusText = "✗ \(error.localizedDescription)"
            logActivity("Couldn't delete the Random gallery: \(error.localizedDescription)", success: false)
        }
    }

    /// Creates a new, empty gallery on the device. `ensureGallery` is
    /// best-effort and swallows its own failures (it's normally just a
    /// convenience side-effect of uploading), so success here is judged by
    /// whether the name shows up in the refreshed gallery list afterward.
    public func createGallery(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusText = "Enter a gallery name."
            return
        }
        guard !galleries.contains(trimmed) else {
            statusText = "'\(trimmed)' already exists."
            return
        }
        isBusy = true
        defer { isBusy = false }
        statusText = "→ PUT /gallery?name=\(trimmed)"
        await client.ensureGallery(ip: settings.deviceIP, name: trimmed)

        // The PUT itself completing doesn't mean /gallery/list reflects it
        // yet — this device's HTTP server has shown eventual-consistency lag
        // elsewhere in testing (thumbnails, listings), so a re-fetch straight
        // after can genuinely miss a gallery that was just created
        // successfully. Retry the listing a few times before concluding
        // failure, same shape as the reachability poll used for BLE wake.
        for attempt in 1...4 {
            await loadGalleries()
            if galleries.contains(trimmed) { break }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        let created = galleries.contains(trimmed)
        statusText = created ? "✓ Created '\(trimmed)'" : "✗ Couldn't create '\(trimmed)'"
        logActivity(created ? "Created gallery '\(trimmed)'" : "Couldn't create gallery '\(trimmed)'", success: created)
    }

    /// Deletes an entire gallery and all its images from the device, and
    /// drops it from any tab/selection it was part of so the UI doesn't keep
    /// referencing a gallery that no longer exists.
    public func deleteGalleryOnDevice(_ name: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            statusText = "→ DELETE /gallery?name=\(name)"
            try await withWakeRetry { try await client.deleteGallery(ip: settings.deviceIP, name: name) }
            statusText = "← /gallery OK"
            settings.selectedGalleries.remove(name)
            for index in settings.tabs.indices {
                settings.tabs[index].galleryNames.remove(name)
            }
            await loadGalleries()
            statusText = "✓ Deleted '\(name)'"
            logActivity("Deleted gallery '\(name)'", success: true)
        } catch {
            statusText = "✗ Couldn't delete '\(name)': \(error.localizedDescription)"
            logActivity("Couldn't delete gallery '\(name)': \(error.localizedDescription)", success: false)
        }
    }


}
