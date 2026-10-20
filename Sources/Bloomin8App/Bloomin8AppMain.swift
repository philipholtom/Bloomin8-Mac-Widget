import Bloomin8Core
import AppKit
import SwiftUI
import os

/// Owns the two long-lived objects the whole window tree shares. Held by a
/// single `@StateObject` so `PhotoController` can be handed the same
/// `AppSettings` instance it was built from.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let controller: PhotoController
    let scheduledSendManager: ScheduledSendManager
    let scheduledContentManager: ScheduledContentManager
    let photosMirrorManager: PhotosMirrorManager

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.controller = PhotoController(settings: settings)
        self.scheduledSendManager = ScheduledSendManager(controller: controller, settings: settings)
        self.scheduledContentManager = ScheduledContentManager(controller: controller, settings: settings)
        self.photosMirrorManager = PhotosMirrorManager(controller: controller, settings: settings)
        MuseumCardServer.shared.start(settings: settings, controller: controller)
    }
}

/// `WindowGroup`'s built-in "click the Dock icon to bring the window back"
/// isn't firing on this setup — confirmed directly: after closing the
/// window and clicking the Dock icon, the process stays alive and correctly
/// foregrounded, but zero windows exist afterward, not even an off-screen
/// one. So this asks explicitly instead of relying on the implicit default.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openWindowAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes Finder's right-click "Send to Frame" (declared under
        // NSServices in Info-App.plist) call `sendToFrame` below.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Open With → Bloomin8 Mac, or photos dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    /// Finder's "Send to Frame" service.
    @objc func sendToFrame(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No photos were received."
            return
        }
        receive(urls)
    }

    /// Hands image files to the window (which asks what to do with them) and
    /// brings the app forward, reopening its window if it had been closed.
    private func receive(_ urls: [URL]) {
        let images = urls.filter { ImageFolder.imageFileExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return }
        Task { @MainActor in
            IncomingFiles.shared.urls = images
            NSApp.activate(ignoringOtherApps: true)
            if NSApp.windows.filter({ $0.isVisible }).isEmpty { openWindowAction?() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openWindowAction?()
        }
        return true
    }
}

/// SwiftUI App lifecycle rather than an AppKit `NSWindow` +
/// `NSHostingController`: `NavigationSplitView` needs a real `Scene` to wire
/// up its columns, and inside a hand-built window it renders but its sidebar
/// selection never binds — rows don't even highlight. The `Scene` also gives
/// us the standard menu bar for free.
@main
struct Bloomin8AppMain: App {
    @StateObject private var env = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "ui")

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(settings: env.settings, controller: env.controller, scheduledSendManager: env.scheduledSendManager, scheduledContentManager: env.scheduledContentManager, photosMirrorManager: env.photosMirrorManager)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    Self.log.notice("app: window appeared")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .background(WindowOpenerCapture(appDelegate: appDelegate))
        }
        .defaultSize(width: 1180, height: 760)
    }
}

/// Invisible — exists only to capture `@Environment(\.openWindow)` from a
/// genuine View context (the only place it's guaranteed to resolve
/// correctly; reading it directly on the `App` type is not a documented,
/// reliable path) and hand the action to `AppDelegate`, which can't read
/// `@Environment` itself.
private struct WindowOpenerCapture: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                appDelegate.openWindowAction = { openWindow(id: "main") }
            }
    }
}
