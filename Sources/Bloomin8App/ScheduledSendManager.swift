import Bloomin8Core
import Combine
import Foundation

/// The windowed app's runner for `AppSettings.scheduledSend`. The always-on
/// widget watches the same schedule as a backup (a minute later); whichever
/// gets there first claims the occurrence, so it runs once. Watching the
/// real clock (not a one-shot `Timer`) means a Mac that was asleep at the
/// set time still runs it on wake.
@MainActor
final class ScheduledSendManager: ObservableObject {
    private let watcher: ScheduleWatcher
    private var cancellable: AnyCancellable?

    /// When the schedule will next fire, for display in Settings — nil if
    /// disabled or incomplete.
    @Published private(set) var nextFireDate: Date?

    init(controller: PhotoController, settings: AppSettings) {
        watcher = ScheduleWatcher(
            name: "scheduled-send",
            timing: { [weak settings] in
                guard let send = settings?.storedActiveProfile()?.scheduledSend,
                      send.isEnabled, !send.devicePath.isEmpty, !send.days.isEmpty else { return nil }
                return ScheduleTiming(days: send.days, timeMinutes: send.timeMinutes)
            },
            run: { [weak controller, weak settings] in
                guard let send = settings?.storedActiveProfile()?.scheduledSend, send.isEnabled else { return }
                await controller?.fireScheduledSend(send)
            }
        )
        cancellable = watcher.$nextFireDate.sink { [weak self] in self?.nextFireDate = $0 }
        watcher.start()
        // Settings edits should show their new next-fire time straight away
        // rather than at the next 30-second look.
        settingsCancellable = Publishers.CombineLatest(settings.$frameProfiles, settings.$activeFrameProfileID)
            .map { _, _ in () }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.watcher.tick() }
            }
    }

    private var settingsCancellable: AnyCancellable?
}
