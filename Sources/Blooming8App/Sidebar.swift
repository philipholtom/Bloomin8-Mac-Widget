import Blooming8Core
import SwiftUI
import os

struct Sidebar: View {
    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "ui")

    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    @ObservedObject private var cardStore = MuseumCardStore.shared
    @Binding var source: LibrarySource?
    /// Picks image files and uploads them into the named gallery.
    let onUpload: (String) -> Void
    /// Opens the backup sheet — with that gallery ticked, or all of them for nil.
    let onBackup: (String?) -> Void

    @State private var showNewGallerySheet = false
    @State private var newGalleryName = ""
    @State private var galleryPendingDeletion: String?

    var body: some View {
        // The footer is a plain sibling below the ScrollView, not a
        // `.safeAreaInset` on top of it. `statusFooter` shows
        // `controller.statusText`, which changes continuously (and changes
        // line count) while a wake/refresh/load is in flight. As an inset
        // over the same scroll view as the clickable rows, any resize of the
        // footer reflows every row above it — so a status update landing
        // between the moment you see a row and the moment your click
        // registers can shift that row out from under the cursor and hand
        // the tap to whatever row moved into its place. Isolating the footer
        // to a fixed-height sibling makes it structurally unable to move the
        // rows, however often its content changes.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeader("Frame")
                    row(.currentPhoto)

                    sectionHeader("Library")
                    if shouldShowLocalFolderRows {
                        row(.localFolder, isLocked: isLocalFolderLocked)
                        row(.browseFiles, isLocked: isLocalFolderLocked)
                        row(.museumCards, badge: cardStore.snapshot.cards.count, isLocked: isLocalFolderLocked)
                        row(.favorites, badge: settings.favoriteImagePaths.count, isLocked: isLocalFolderLocked)
                    }
                    row(.applePhotos)
                    row(.generated)

                    galleriesHeader
                    ForEach(visibleGalleries, id: \.self) { name in
                        row(.gallery(name), isLocked: lockedTab(for: name) != nil)
                            .contextMenu {
                                Button("Upload Photos…") { onUpload(name) }
                                Button("Back Up Gallery…") { onBackup(name) }
                                Button("Download Gallery…") {
                                    guard let folder = FilePicker.chooseFolder() else { return }
                                    Task { await controller.downloadGallery(name, to: folder) }
                                }
                                Divider()
                                Button("Delete Gallery…", role: .destructive) {
                                    galleryPendingDeletion = name
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            .frame(maxHeight: .infinity)

            statusFooter
        }
        // Invisible — mirrors the widget's ⌘⇧L: reveals galleries (and, when
        // password-protected, Local Folder/Favorites) behind a still-locked
        // row, without a visible control anyone could stumble onto.
        // Selecting one still requires the password; this only controls
        // whether the row appears at all.
        .background(
            Button("") { controller.showHiddenTabs.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .alert(
            "Delete '\(galleryPendingDeletion ?? "")'?",
            isPresented: Binding(get: { galleryPendingDeletion != nil }, set: { if !$0 { galleryPendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { galleryPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let name = galleryPendingDeletion else { return }
                galleryPendingDeletion = nil
                if source == .gallery(name) { source = nil }
                Task { await controller.deleteGalleryOnDevice(name) }
            }
        } message: {
            Text("This removes the gallery and every photo in it from the frame. This can't be undone.")
        }
    }

    /// Unlike the other sections, shown even with zero galleries — the "+"
    /// button is the only way to create one, so it needs to always be there.
    private var galleriesHeader: some View {
        HStack {
            sectionHeader("Galleries")
            Spacer()
            Button {
                onBackup(nil)
            } label: {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Back up galleries to a folder on this Mac")

            Button {
                newGalleryName = ""
                showNewGallerySheet = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .padding(.trailing, 8)
            .help("New Gallery")
            .popover(isPresented: $showNewGallerySheet) {
                newGalleryPopover
            }
        }
    }

    private var newGalleryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Gallery")
                .font(.headline)
            TextField("Gallery name", text: $newGalleryName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { createGallery() }
            HStack {
                Spacer()
                Button("Cancel") { showNewGallerySheet = false }
                Button("Create") { createGallery() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newGalleryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func createGallery() {
        let name = newGalleryName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showNewGallerySheet = false
        Task { await controller.createGallery(name: name) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    /// Galleries assigned to a still-locked tab stay hidden until ⌘⇧L
    /// reveals them (matching the widget's tab bar), and even then still
    /// require the password to actually open — selecting one routes to
    /// `LockedGalleryPrompt` rather than the grid until it's unlocked.
    private var visibleGalleries: [String] {
        guard !controller.showHiddenTabs else { return controller.galleries }
        let lockedNames = settings.tabs
            .filter { $0.isLocked && !controller.unlockedTabIDs.contains($0.id) }
            .flatMap(\.galleryNames)
        let hidden = Set(lockedNames)
        return controller.galleries.filter { !hidden.contains($0) }
    }

    private func lockedTab(for galleryName: String) -> GalleryTab? {
        settings.lockedTab(for: galleryName, unlockedTabIDs: controller.unlockedTabIDs)
    }

    private var isLocalFolderLocked: Bool {
        settings.localFolderLocked && !controller.isLocalFolderUnlocked
    }

    /// Hidden from the sidebar entirely — not just locked — while
    /// password-protected and not yet unlocked this session, same as a
    /// locked gallery tab: ⌘⇧L reveals the row (still password-gated to
    /// actually open), and it stays visible once unlocked without needing
    /// ⌘⇧L again. An unprotected Local Folder/Favorites is unaffected and
    /// always shows.
    private var shouldShowLocalFolderRows: Bool {
        !settings.localFolderLocked || controller.isLocalFolderUnlocked || controller.showHiddenTabs
    }

    /// A plain tappable row rather than `List(selection:)`. That binding
    /// never fired inside `NavigationSplitView`'s sidebar column — clicking a
    /// row produced no selection change at all, on a window confirmed to be
    /// real, on-screen, and receiving other input. The actual root cause
    /// turned out to be `NavigationSplitView` itself misdelivering clicks in
    /// its sidebar column on this OS version (fixed by using `HSplitView`
    /// instead, in `RootView`); this plain-Button structure predates that
    /// fix and is kept because it's simpler than `List(selection:)` for a
    /// fixed set of rows regardless.
    @ViewBuilder
    private func row(_ item: LibrarySource, badge: Int? = nil, isLocked: Bool = false) -> some View {
        if #available(macOS 14.0, *) {
            rowButton(item, badge: badge, isLocked: isLocked)
                .focusEffectDisabled()
        } else {
            rowButton(item, badge: badge, isLocked: isLocked)
        }
    }

    private func rowButton(_ item: LibrarySource, badge: Int?, isLocked: Bool) -> some View {
        let isSelected = source == item
        return Button {
            Self.log.notice("row tapped: \(item.title, privacy: .public)")
            source = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .frame(width: 18)
                Text(item.title)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Fixed height regardless of content: `controller.statusText` varies in
    /// length and appears/disappears as operations run, and this view must
    /// never resize in response — see the comment in `body` for why.
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(awakeColor)
                    .frame(width: 7, height: 7)
                Text(awakeLabel)
                Spacer()
                if let battery = controller.batteryPercent {
                    Image(systemName: batterySymbol(battery))
                    Text("\(battery)%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let name = controller.deviceName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(controller.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .opacity(controller.statusText.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(height: 78, alignment: .top)
        .clipped()
    }

    private var awakeColor: Color {
        switch controller.isDeviceAwake {
        case .some(true): return .green
        case .some(false): return .secondary
        case nil: return .clear
        }
    }

    private var awakeLabel: String {
        switch controller.isDeviceAwake {
        case .some(true): return "Awake"
        case .some(false): return "Asleep"
        case nil: return "Not connected"
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
