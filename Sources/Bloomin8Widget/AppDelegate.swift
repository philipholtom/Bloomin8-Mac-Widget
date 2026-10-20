import Bloomin8Core
import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var contentView: ContentView?
    private let settings = AppSettings()
    private lazy var controller = PhotoController(settings: settings)
    /// Backup runners for the schedules the windowed app normally owns: they
    /// act a minute after the set time and only if the app hasn't already
    /// claimed that day's run (it isn't open overnight, and the widget is).
    private var backupWatchers: [ScheduleWatcher] = []
    private var activityToken: NSObjectProtocol?
    private var awakeStatusCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MuseumCardServer.shared.start(settings: settings, controller: controller)
        startBackupSchedules()

        // A menu bar app has no visible windows, so macOS App Nap would
        // otherwise throttle its timers — this keeps the auto-random
        // schedule firing on time while still allowing the system to sleep.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Scheduled random photo updates"
        )

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem
        updateStatusIcon(isAwake: nil)

        // The icon can't observe @Published properties on its own like a
        // SwiftUI view would, so mirror isDeviceAwake into it manually.
        awakeStatusCancellable = controller.$isDeviceAwake
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAwake in
                self?.updateStatusIcon(isAwake: isAwake)
            }

        let contentView = ContentView(settings: settings, controller: controller)
        let hostingController = NSHostingController(rootView: contentView)
        // Let the popover grow/shrink to fit however many galleries are listed,
        // instead of a fixed height that needs an inner scroll view.
        hostingController.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hostingController
        self.popover = popover
        self.contentView = contentView
    }

    /// Sets the menu bar icon's shape/color to reflect whether the frame is
    /// currently reachable: green when awake, a dimmed "sleeping" icon when
    /// it isn't (asleep is a normal battery-saving state for this device,
    /// not an error, hence gray/blue rather than red), or the plain
    /// template icon when there's nothing to report yet.
    private func updateStatusIcon(isAwake: Bool?) {
        guard let button = statusItem?.button else { return }
        switch isAwake {
        case .some(true):
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Bloomin8 (frame awake)")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
        case .some(false):
            let config = NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
            let image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "Bloomin8 (frame asleep)")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
        case .none:
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Bloomin8")
            image?.isTemplate = true
            button.image = image
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender as AnyObject)
        }
    }

    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            contentView?.resetHiddenTabVisibility()
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Random Photo", action: #selector(randomPhotoFromMenu), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Redisplay Photo", action: #selector(redisplayFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Show Next", action: #selector(showNextFromMenu), keyEquivalent: "n")
            .target = self
        menu.addItem(withTitle: "Wake Frame", action: #selector(wakeFrameFromMenu), keyEquivalent: "w")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Bloomin8 Widget", action: #selector(quitApp), keyEquivalent: "q")
            .target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Detach the menu afterward so left-clicks go back to toggling the popover
        // instead of always opening this menu.
        statusItem?.menu = nil
    }

    @objc private func randomPhotoFromMenu() {
        Task { await controller.showRandomPhoto() }
    }

    @objc private func redisplayFromMenu() {
        Task { await controller.redisplayCurrentPhoto() }
    }

    @objc private func showNextFromMenu() {
        Task { await controller.showNextImage() }
    }

    @objc private func wakeFrameFromMenu() {
        Task { await controller.wakeFrame() }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startBackupSchedules() {
        let settings = settings
        let controller = controller
        let content = ScheduleWatcher(
            name: "scheduled-content", delay: 60,
            timing: {
                // The Photos "on this day" pick needs the app's Photos access.
                guard let c = settings.storedActiveProfile()?.scheduledContent, c.isEnabled, !c.days.isEmpty,
                      c.sourceID != ScheduledContent.onThisDayPhotosSourceID else { return nil }
                return ScheduleTiming(days: c.days, timeMinutes: c.timeMinutes)
            },
            run: {
                guard let c = settings.storedActiveProfile()?.scheduledContent, c.isEnabled else { return }
                await controller.fireScheduledContent(c)
            }
        )
        let send = ScheduleWatcher(
            name: "scheduled-send", delay: 60,
            timing: {
                guard let s = settings.storedActiveProfile()?.scheduledSend, s.isEnabled,
                      !s.devicePath.isEmpty, !s.days.isEmpty else { return nil }
                return ScheduleTiming(days: s.days, timeMinutes: s.timeMinutes)
            },
            run: {
                guard let s = settings.storedActiveProfile()?.scheduledSend, s.isEnabled else { return }
                await controller.fireScheduledSend(s)
            }
        )
        backupWatchers = [content, send]
        backupWatchers.forEach { $0.start() }
    }
}
