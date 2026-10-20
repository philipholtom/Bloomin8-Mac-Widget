import Bloomin8Core
import Combine
import Foundation
import Photos

/// Keeps a frame gallery in step with a Photos album — see `PhotosMirror`.
///
/// Automatic checks run shortly after launch and then every half hour while
/// the app is open. They are deliberately gentle on a battery-powered frame:
/// they do nothing unless the album has actually changed since the last
/// sync (checked locally, without contacting the frame), and never wake a
/// sleeping frame — they wait for it to be awake. "Sync Now" always goes
/// ahead, waking the frame if it has to.
///
/// Only the windowed app does this, for the same reason as the other
/// schedules: it should happen once, and this app owns the Photos access.
@MainActor
final class PhotosMirrorManager: ObservableObject {
    private let controller: PhotoController
    private let settings: AppSettings
    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var firstCheck: Task<Void, Never>?

    @Published private(set) var isSyncing = false
    /// Live progress while syncing, e.g. "Uploading 6–10 of 24…".
    @Published private(set) var progressText = ""
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastSyncDate: Date?

    private static let checkInterval: TimeInterval = 30 * 60

    init(controller: PhotoController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        // Pulled out of the DELIVERED profiles and de-duplicated, as in the
        // other managers (see ScheduledSendManager.init for why).
        cancellable = Publishers.CombineLatest(settings.$frameProfiles, settings.$activeFrameProfileID)
            .map { profiles, activeID in profiles.first(where: { $0.id == activeID })?.photosMirror }
            .removeDuplicates()
            .sink { [weak self] mirror in
                self?.reschedule(with: mirror)
            }
    }

    private func reschedule(with mirror: PhotosMirror?) {
        timer?.invalidate()
        timer = nil
        firstCheck?.cancel()
        guard let mirror, mirror.isEnabled, !mirror.albumID.isEmpty, !mirror.gallery.isEmpty else { return }

        // A short wait lets the frame's first status check come back before
        // the first look, so "is it awake?" has an answer.
        firstCheck = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await syncNow(automatic: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncNow(automatic: true)
            }
        }
    }

    /// One pass: add what's new in the album, optionally remove what left it.
    /// `reshuffle` (random mode only) picks a fresh set of photos first.
    func syncNow(automatic: Bool = false, reshuffle: Bool = false) async {
        guard !isSyncing,
              let mirror = settings.photosMirror,
              !mirror.albumID.isEmpty, !mirror.gallery.isEmpty
        else { return }
        isSyncing = true
        defer { isSyncing = false; progressText = "" }
        let profileID = settings.activeFrameProfileID

        if automatic {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
        } else if !(await PhotosLibrarySource.requestAccess()) {
            finish("Photos access denied. Enable it for Bloomin8 Mac in System Settings → Privacy & Security → Photos.", success: false, record: true)
            return
        }

        progressText = "Reading the album…"
        let albumID = mirror.albumID
        let assets = await Task.detached(priority: .userInitiated) {
            PhotosLibrarySource.fetchImageAssets(inAlbum: albumID)
        }.value

        // An empty result might be a deleted album: never act on it, least of
        // all by removing everything from the frame.
        guard !assets.isEmpty else {
            if !automatic { finish("“\(mirror.albumTitle)” has no photos, or no longer exists — nothing was changed.", success: false, record: true) }
            return
        }

        let albumIDs = assets.map(\.localIdentifier)
        var state = PhotosMirrorState.load(profileID: profileID)

        // Which photos to mirror: the newest N, or a random N that stays put
        // between syncs until it's shuffled (by hand, or on the chosen schedule).
        let ids: [String]
        switch mirror.mode {
        case .newest:
            ids = Array(albumIDs.prefix(mirror.maxPhotos))
        case .random:
            let interval = mirror.reshuffle.interval
            let due = reshuffle
                || state.selection.isEmpty
                || (interval.map { limit in state.lastShuffle.map { Date().timeIntervalSince($0) >= limit } ?? true } ?? false)
            var generator = SystemRandomNumberGenerator()
            let chosen = PhotosMirrorState.randomSelection(albumIDs: albumIDs, previous: state.selection, count: mirror.maxPhotos, reshuffle: due, using: &generator)
            if due || chosen != state.selection {
                state.selection = chosen
                if due { state.lastShuffle = Date() }
                PhotosMirrorState.save(state, profileID: profileID)
            }
            ids = chosen
        }
        let expected = ids.map { controller.mirrorFilename(forPhotosAsset: $0) }
        let expectedSet = Set(expected)

        if automatic {
            // Nothing new since the last sync: no need to trouble the frame at all.
            if state.names == expectedSet { return }
            // And don't wake a sleeping frame (and its battery) for this.
            guard controller.isDeviceAwake == true, !controller.isBusy else { return }
        }

        do {
            progressText = "Checking what's on the frame…"
            await controller.ensureFrameGallery(mirror.gallery)
            let existing = Set(try await controller.listFrameGallery(mirror.gallery))

            let toAdd = zip(ids, expected).filter { !existing.contains($0.1) }
            let toRemove = mirror.removeDeleted
                ? existing.filter { PhotosMirror.isMirrorFilename($0) && !expectedSet.contains($0) }.sorted()
                : []

            var failed: [String] = []
            var index = 0
            while index < toAdd.count {
                if Task.isCancelled { break }
                let slice = Array(toAdd[index..<min(index + 5, toAdd.count)])
                progressText = "Uploading \(index + 1)–\(index + slice.count) of \(toAdd.count)…"

                var items: [(filename: String, data: Data)] = []
                await withTaskGroup(of: (String, Data?).self) { group in
                    for (id, name) in slice {
                        group.addTask { (name, await PhotosLibrarySource.fetchOriginalData(assetID: id)) }
                    }
                    for await (name, data) in group {
                        if let data { items.append((name, data)) } else { failed.append(name) }
                    }
                }
                if !items.isEmpty {
                    failed.append(contentsOf: await controller.uploadPhotoBatch(items, to: mirror.gallery))
                }
                index += slice.count
            }

            var removed = 0
            if !toRemove.isEmpty {
                progressText = "Removing \(toRemove.count) photo\(toRemove.count == 1 ? "" : "s") no longer in the album…"
                removed = await controller.removeFromFrameGallery(mirror.gallery, filenames: toRemove)
            }

            // Remember what is now on the frame, leaving out anything that
            // failed so the next automatic check tries those again.
            state.names = expectedSet.subtracting(failed)
            PhotosMirrorState.save(state, profileID: profileID)
            await controller.loadGalleries()

            let added = toAdd.count - failed.count
            var summary = "“\(mirror.albumTitle)” → \(mirror.gallery): "
            summary += (added == 0 && removed == 0) ? "already up to date" : "added \(added), removed \(removed)"
            if !failed.isEmpty { summary += ", \(failed.count) failed" }
            finish(summary, success: failed.isEmpty, record: !automatic || added > 0 || removed > 0 || !failed.isEmpty)
        } catch {
            finish("Couldn't sync “\(mirror.albumTitle)”: \(error.localizedDescription)", success: false, record: !automatic)
        }
    }

    private func finish(_ summary: String, success: Bool, record: Bool) {
        lastSummary = summary
        lastSyncDate = Date()
        if record {
            controller.logActivity("Photos mirror — " + summary, success: success)
            controller.statusText = summary
        }
    }
}
