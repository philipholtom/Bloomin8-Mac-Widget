import Blooming8Core
import Combine
import Foundation

/// The clock-driven trigger for `AppSettings.scheduledContent` — a generated
/// picture (e.g. today's NASA Photo of the Day) shown at a set time on chosen
/// days. The windowed app is the primary runner (it alone can do the Photos
/// "on this day" choice); the always-on widget backs it up a minute later for
/// everything else, and a claim file makes sure each day runs once. If the Mac
/// is asleep at the set time, it runs on wake.
@MainActor
final class ScheduledContentManager: ObservableObject {
    private let controller: PhotoController
    private let settings: AppSettings
    private var watcher: ScheduleWatcher!
    private var cancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?

    /// When it will next fire, for display in Settings — nil if disabled or
    /// incomplete.
    @Published private(set) var nextFireDate: Date?

    init(controller: PhotoController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        watcher = ScheduleWatcher(
            name: "scheduled-content",
            timing: { [weak settings] in
                guard let content = settings?.storedActiveProfile()?.scheduledContent,
                      content.isEnabled, !content.days.isEmpty else { return nil }
                return ScheduleTiming(days: content.days, timeMinutes: content.timeMinutes)
            },
            run: { [weak self, weak settings] in
                guard let content = settings?.storedActiveProfile()?.scheduledContent, content.isEnabled else { return }
                await self?.run(content)
            }
        )
        cancellable = watcher.$nextFireDate.sink { [weak self] in self?.nextFireDate = $0 }
        watcher.start()
        settingsCancellable = Publishers.CombineLatest(settings.$frameProfiles, settings.$activeFrameProfileID)
            .map { _, _ in () }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.watcher.tick() }
            }
    }

    /// Does what `schedule` says right now — also the "Run Now" button in
    /// Settings. A photo from Photos "on this day" is handled here because
    /// only the windowed app has the Photos access; everything else is a
    /// generated picture and goes through the controller.
    func run(_ schedule: ScheduledContent) async {
        if schedule.sourceID == ScheduledContent.onThisDayPhotosSourceID {
            await sendOnThisDayPhoto()
        } else {
            await controller.fireScheduledContent(schedule)
        }
    }

    private func sendOnThisDayPhoto() async {
        guard await PhotosLibrarySource.requestAccess() else {
            controller.statusText = "Photos access denied. Enable it for Blooming8 in System Settings → Privacy & Security → Photos."
            controller.logActivity("On this day: Photos access denied", success: false)
            return
        }
        let pool = await Task.detached(priority: .userInitiated) { () -> [String] in
            let exact = PhotosLibrarySource.fetchOnThisDay()
            return (exact.isEmpty ? PhotosLibrarySource.fetchOnThisDay(toleranceDays: 3) : exact).map(\.localIdentifier)
        }.value
        guard let id = pool.randomElement() else {
            controller.statusText = "No photos from this day in earlier years."
            controller.logActivity("On this day: no photos from earlier years", success: true)
            return
        }
        guard let data = await PhotosLibrarySource.fetchOriginalData(assetID: id) else {
            controller.logActivity("On this day: couldn't read the photo from Photos", success: false)
            return
        }
        controller.preparePhotosLibraryImage(data: data, displayName: PhotosLibrarySource.displayName(forAssetID: id), assetID: id)
        guard let candidate = controller.localFolderCandidates.first else { return }
        await controller.confirmLocalFolderCandidate(candidate)
        controller.cancelLocalFolderCandidate()
    }
}
