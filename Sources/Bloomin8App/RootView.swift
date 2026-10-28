import Bloomin8Core
import AppKit
import SwiftUI
import os

struct RootView: View {
    fileprivate static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "ui")

    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    @ObservedObject var scheduledSendManager: ScheduledSendManager
    @ObservedObject var scheduledContentManager: ScheduledContentManager
    @ObservedObject var photosMirrorManager: PhotosMirrorManager
    @StateObject private var library: LibraryModel
    @ObservedObject private var incoming = IncomingFiles.shared
    @ObservedObject private var privacy = PrivacyBlur.shared

    @State private var source: LibrarySource? = .currentPhoto
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showActivity = false
    @State private var showSendRemotely = false
    @State private var thumbnailSize: Double = 150
    @State private var showDeleteGalleryConfirm = false
    @State private var backupRequest: BackupRequest?

    init(settings: AppSettings, controller: PhotoController, scheduledSendManager: ScheduledSendManager, scheduledContentManager: ScheduledContentManager, photosMirrorManager: PhotosMirrorManager) {
        self.settings = settings
        self.controller = controller
        self.scheduledSendManager = scheduledSendManager
        self.scheduledContentManager = scheduledContentManager
        self.photosMirrorManager = photosMirrorManager
        _library = StateObject(wrappedValue: LibraryModel(settings: settings, controller: controller))
    }

    var body: some View {
        // HSplitView, not NavigationSplitView: the sidebar's clicks
        // resolved to the wrong row, consistently and reproducibly, no
        // matter what changed in Sidebar's own view code. Diagnostic
        // logging confirmed clicks at genuinely different screen positions
        // were all being reported at nearly the same coordinate — the input
        // wasn't reaching this code with the right position in the first
        // place. Replacing NavigationSplitView's sidebar column (newer and
        // more complex than the long-stable HSplitView already used for the
        // grid/inspector split below) with HSplitView here resolved it.
        HSplitView {
            Sidebar(settings: settings, controller: controller, source: $source, onUpload: uploadPhotos(to:), onBackup: { name in
                backupRequest = BackupRequest(preselected: name.map { [$0] })
            })
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            detail
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                // The unstyled default here is NSColor.windowBackgroundColor
                // — deliberately a soft grey "chrome" tone, not meant to be
                // content itself. textBackgroundColor is the semantic match
                // for an actual content/document pane (what NSTextView,
                // Mail's message body, etc. use): near-white in light mode,
                // and — unlike a literal .white — still correct if the
                // system is ever in Dark Mode. Sidebar is left as the system
                // default; a grey sidebar next to a white content pane is
                // the standard Finder/Mail/Photos convention, not the thing
                // that reads as "grey" here.
                .background(Color(nsColor: .textBackgroundColor))
        }
        .toolbar { toolbarContent }
        .navigationTitle(activeSource.title)
        .task {
            guard !settings.deviceIP.isEmpty else {
                showSettings = true
                return
            }
            await controller.refreshCurrentPhoto()
            await controller.loadGalleries()
        }
        .onChange(of: source) { newValue in
            let resolved = newValue ?? .currentPhoto
            Self.log.notice("sidebar: selected \(resolved.title, privacy: .public)")
            // Deliberately no re-lock here: isLocalFolderUnlocked lives only
            // in memory on PhotoController, so quitting the app already
            // clears it on its own — re-locking on every navigation away
            // (the previous behavior) meant anything outside Local Folder's
            // own view, like the Frame pane's "Random from Local Folder"
            // button, saw it as locked again the instant you clicked
            // elsewhere to reach that button in the first place.
            library.load(resolved)
        }
        .onChange(of: settings.favoriteImagePaths) { _ in
            if activeSource == .favorites { library.load(.favorites) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: settings, controller: controller, scheduledSendManager: scheduledSendManager, scheduledContentManager: scheduledContentManager, photosMirrorManager: photosMirrorManager)
        }
        .sheet(isPresented: $showLogs) {
            DeviceLogsView(settings: settings)
        }
        .sheet(isPresented: $showActivity) {
            ActivitySheet(controller: controller)
        }
        .sheet(item: $backupRequest) { request in
            BackupSheet(request: request, controller: controller, settings: settings)
        }
        .sheet(isPresented: Binding(get: { !incoming.urls.isEmpty }, set: { if !$0 { incoming.urls = [] } })) {
            IncomingFilesSheet(urls: incoming.urls, controller: controller, settings: settings)
        }
        .sheet(isPresented: $showSendRemotely) {
            SendRemotelyView(settings: settings, controller: controller)
        }
        .alert("Delete '\(activeGalleryName ?? "")'?", isPresented: $showDeleteGalleryConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let name = activeGalleryName else { return }
                Task {
                    await controller.deleteGalleryOnDevice(name)
                    // The gallery being viewed no longer exists — fall back
                    // to the frame pane rather than showing an empty grid.
                    source = nil
                }
            }
        } message: {
            Text("This removes the gallery and every photo in it from the frame. This can't be undone.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if case .gallery(let name) = activeSource, let lockedTab = lockedGalleryTab(name) {
            LockedGalleryPrompt(tab: lockedTab, controller: controller, settings: settings)
        } else if isLocalFolderSource, settings.localFolderLocked, !controller.isLocalFolderUnlocked {
            LockedLocalFolderPrompt(settings: settings, controller: controller)
        } else {
            detailForUnlockedSource
        }
    }

    private func isLocalFolderSource(_ source: LibrarySource) -> Bool {
        source == .localFolder || source == .browseFiles || source == .museumCards || source == .favorites
    }

    private var isLocalFolderSource: Bool { isLocalFolderSource(activeSource) }

    @ViewBuilder
    private var detailForUnlockedSource: some View {
        switch activeSource {
        case .currentPhoto:
            CurrentPhotoPane(
                controller: controller,
                settings: settings,
                scheduledSendManager: scheduledSendManager,
                scheduledContentManager: scheduledContentManager,
                photosMirrorManager: photosMirrorManager,
                openAutomationSettings: {
                    // SettingsSheet remembers its last page under this key.
                    UserDefaults.standard.set("Automation", forKey: "settingsSheetCategory")
                    showSettings = true
                },
                openActivity: { showActivity = true }
            )
        case .generated:
            GeneratedPane(settings: settings, controller: controller)
        case .browseFiles:
            FileBrowserView(settings: settings, controller: controller)
        case .museumCards:
            MuseumCardsView(settings: settings, controller: controller)
        case .playlists:
            PlaylistsView(settings: settings, controller: controller)
        default:
            HSplitView {
                LibraryGrid(
                    library: library,
                    settings: settings,
                    controller: controller,
                    thumbnailSize: thumbnailSize
                )
                .frame(minWidth: 420)

                if let item = library.selectedItem {
                    InspectorPane(item: item, settings: settings, controller: controller)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                }
            }
        }
    }

    /// The still-locked tab a gallery belongs to, if `activeSource` is that
    /// gallery and it hasn't been unlocked this session. Checked here rather
    /// than at the sidebar-click site: `unlockedTabIDs` can change (via
    /// `LockedGalleryPrompt`) without `source` itself changing, so the detail
    /// view needs to re-evaluate on every render, not just once per click.
    private func lockedGalleryTab(_ name: String) -> GalleryTab? {
        settings.lockedTab(for: name, unlockedTabIDs: controller.unlockedTabIDs)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if controller.isBusy {
                ProgressView().controlSize(.small)
            }

            if settings.frameProfiles.count > 1 {
                Menu {
                    ForEach(settings.frameProfiles) { profile in
                        Button {
                            switchToFrameProfile(profile.id)
                        } label: {
                            if profile.id == settings.activeFrameProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    ToolbarLabel(title: activeFrameProfileName, systemImage: "photo.on.rectangle.angled")
                }
                .help("Switch which frame this app is controlling")
            }

            Button {
                Task { await controller.refreshCurrentPhoto() }
            } label: {
                ToolbarLabel(title: "Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read what the frame is currently showing")

            Button {
                Task { await controller.wakeFrame() }
            } label: {
                ToolbarLabel(title: "Wake", systemImage: "sun.max")
            }
            .help("Send a Bluetooth wake pulse to the frame")

            // A plain Button carrying its own on/off look rather than a
            // `Toggle` with `.toggleStyle(.button)`: the toggle sized itself
            // narrower than its label and clipped it ("Keep Awa").
            Button {
                controller.keepAwake.toggle()
            } label: {
                ToolbarLabel(title: "Keep Awake", systemImage: controller.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(controller.keepAwake ? Color.accentColor : Color.primary)
            }
            .help(controller.keepAwake
                ? "Keeping the frame awake — click to let it sleep normally again"
                : "Keep the frame awake instead of letting it idle to sleep (uses battery; turns off by itself if the battery gets low)")

            Button {
                privacy.enabled.toggle()
            } label: {
                ToolbarLabel(title: "Privacy", systemImage: privacy.enabled ? "eye.slash" : "eye")
                    .foregroundStyle(privacy.enabled ? Color.accentColor : Color.primary)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .help(privacy.enabled
                ? "Previews of locked content are hidden — click to show them (⇧⌘B). Right-click for style and strength."
                : "Hide previews of locked galleries, Local Folder and Favorites (⇧⌘B). Right-click for style and strength.")
            .contextMenu { PrivacyBlurStrengthMenu() }

            if isGridSource {
                Slider(value: $thumbnailSize, in: 90...280) {
                    Text("Thumbnail size")
                }
                .frame(width: 110)
                .help("Thumbnail size")
            }

            if let galleryName = activeGalleryName {
                Menu {
                    Button("Upload Photos…") { uploadPhotos(to: galleryName) }
                    Button("Back Up…") { backupRequest = BackupRequest(preselected: [galleryName]) }
                    Button("Download Gallery…") {
                        guard let folder = FilePicker.chooseFolder() else { return }
                        Task { await controller.downloadGallery(galleryName, to: folder) }
                    }
                    Divider()
                    Button("Delete Gallery…", role: .destructive) {
                        showDeleteGalleryConfirm = true
                    }
                } label: {
                    ToolbarLabel(title: "Gallery", systemImage: "ellipsis.circle")
                }
                .help("Download or delete '\(galleryName)'")
            }

            Button {
                showLogs = true
            } label: {
                ToolbarLabel(title: "Logs", systemImage: "doc.text.magnifyingglass")
            }
            .help("View and download the frame's own diagnostic logs")

            Button {
                showActivity = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    ToolbarLabel(title: "Activity", systemImage: "clock.arrow.circlepath")
                    if controller.hasUnseenActivityFailure {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .help("What this app has tried to do to the frame recently, and whether it worked")

            Button {
                showSendRemotely = true
            } label: {
                ToolbarLabel(title: "Remote", systemImage: "antenna.radiowaves.left.and.right")
            }
            .help("Push a photo to the frame over the internet, not just your home network")

            Button {
                showSettings = true
            } label: {
                ToolbarLabel(title: "Settings", systemImage: "gearshape")
            }
        }
    }

    /// Asks for image files and uploads them into `gallery` — the same action
    /// as dropping files onto that gallery's grid, for people who'd rather
    /// pick them than drag them. Reloads the grid afterwards if that gallery
    /// is the one on screen.
    private func uploadPhotos(to gallery: String) {
        let urls = FilePicker.chooseImages()
        guard !urls.isEmpty else { return }
        Task {
            await controller.uploadPhotos(urls: urls, gallery: gallery)
            if activeSource == .gallery(gallery) { library.load(.gallery(gallery)) }
        }
    }

    private var activeFrameProfileName: String {
        settings.frameProfiles.first(where: { $0.id == settings.activeFrameProfileID })?.name ?? "Frame"
    }

    /// Switching which profile is active moves every per-frame field
    /// (`deviceIP`, `tabs`, `galleries`, etc.) onto a different physical
    /// frame — re-fetches its state the same way app launch does, since
    /// `controller`'s cached state still reflects whichever frame was
    /// queried last, and drops back to the "On the Frame" pane rather than
    /// leaving a gallery browse open that may not even exist on the new frame.
    private func switchToFrameProfile(_ id: UUID) {
        settings.activeFrameProfileID = id
        source = .currentPhoto
        // The controller resets and re-reads the new frame itself when the
        // active profile changes.
    }

    private var activeSource: LibrarySource { source ?? .currentPhoto }

    private var activeGalleryName: String? {
        guard case .gallery(let name) = activeSource, lockedGalleryTab(name) == nil else { return nil }
        return name
    }

    private var isGridSource: Bool {
        switch activeSource {
        case .currentPhoto, .generated, .museumCards, .playlists: return false
        default: return true
        }
    }
}


/// An icon with a short caption underneath, for the window toolbar — the
/// default toolbar shows icons only, so what each one does was only
/// discoverable by hovering for its tooltip.
private struct ToolbarLabel: View {
    let title: String
    let systemImage: String

    /// One line, icon then text: a caption stacked under the icon overflowed
    /// the toolbar button's own shape (clipping the bottom of the text), and
    /// `fixedSize` stops a long title like "Keep Awake" being truncated to
    /// "Keep A…" when the toolbar is tight.
    var body: some View {
        HStack(spacing: 5) {
            // A fixed-width icon slot: a button whose icon swaps between an
            // outline and a filled symbol (Keep Awake, Privacy) changes width
            // when toggled, and the toolbar only re-measured it after a click —
            // so it showed clipped until then.
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}
