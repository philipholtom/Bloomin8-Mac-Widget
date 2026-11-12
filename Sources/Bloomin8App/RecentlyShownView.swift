import Bloomin8Core
import AppKit
import SwiftUI

/// Everything that's recently been on the frame, newest first, with one
/// click to put a picture back. Thumbnails come from this Mac's cache when
/// they can, so the list fills in even while the frame is asleep.
struct RecentlyShownView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    @ObservedObject private var cardStore = MuseumCardStore.shared

    @State private var selected: String?
    @State private var confirmingClear = false

    /// Pictures from a still-locked gallery are left out of the list altogether.
    private var visible: [ShownEntry] {
        controller.recentlyShown.filter { entry in
            guard let gallery = PhotoController.galleryName(fromDevicePath: entry.path) else { return true }
            return settings.lockedTab(for: gallery, unlockedTabIDs: controller.unlockedTabIDs) == nil
        }
    }

    private var landscape: Bool { settings.renderWidth > settings.renderHeight }

    var body: some View {
        VStack(spacing: 0) {
            if visible.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Nothing yet").font(.headline)
                    Text("Pictures are listed here as they appear on the frame, while Bloomin8 is open.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: landscape ? 220 : 160), spacing: 14)], spacing: 16) {
                        ForEach(visible) { entry in
                            cell(entry)
                        }
                    }
                    .padding(18)
                }
                Divider()
                actionBar
            }
        }
        .onAppear { controller.reloadRecentlyShown() }
        .confirmationDialog("Clear the recently-shown list?", isPresented: $confirmingClear) {
            Button("Clear List", role: .destructive) { selected = nil; controller.clearRecentlyShown() }
        } message: {
            Text("This only clears the list here. Nothing is deleted from the frame.")
        }
    }

    // MARK: - Cells

    private func cell(_ entry: ShownEntry) -> some View {
        let gallery = PhotoController.galleryName(fromDevicePath: entry.path)
        let isCurrent = controller.currentImagePath == entry.path
        let isSelected = selected == entry.path
        return VStack(alignment: .leading, spacing: 5) {
            RecentThumbnail(settings: settings, path: entry.path, gallery: gallery)
                .aspectRatio(landscape ? 4.0 / 3.0 : 3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        Text("On the frame")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
            Text(title(for: entry)).font(.caption).lineLimit(1)
            Text(relative(entry.shownAt) + (gallery.map { " · \($0)" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        // onTapGesture, not Button: see the SwiftUI quirks noted for lazy grids.
        .onTapGesture(count: 2) { show(entry) }
        .onTapGesture { selected = entry.path }
        .contextMenu {
            Button("Show Again") { show(entry) }
            Button("Remove from List") { controller.removeFromRecentlyShown(entry.path) }
        }
    }

    private func title(for entry: ShownEntry) -> String {
        if let card = cardStore.snapshot.cards[entry.path], !card.title.isEmpty { return card.title }
        return (entry.path as NSString).lastPathComponent
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack {
            if let entry = visible.first(where: { $0.path == selected }) {
                Text(title(for: entry)).font(.callout).lineLimit(1)
                Spacer()
                Button("Remove") { controller.removeFromRecentlyShown(entry.path); selected = nil }
                Button("Show Again") { show(entry) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy)
            } else {
                Text("Click a picture, then Show Again — or double-click it.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Clear List…") { confirmingClear = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func show(_ entry: ShownEntry) {
        selected = entry.path
        Task { await controller.showImageAtPath(entry.path) }
    }
}

/// One picture's thumbnail: this Mac's cached copy at any size first, the
/// frame only if there isn't one. Privacy pixelate/blur applies.
private struct RecentThumbnail: View {
    @ObservedObject var settings: AppSettings
    let path: String
    let gallery: String?

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.15))
            if let image {
                PrivacyImage(image, settings: settings, gallery: gallery)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .privacyBlur(settings: settings, gallery: gallery)
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                    Text("Not available").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            guard image == nil else { return }
            let store = DeviceThumbnailStore.shared
            image = await store.cachedThumbnail(ip: settings.deviceIP, path: path, sizes: [320, 300, 700, 160])
            if image == nil { image = await store.thumbnail(ip: settings.deviceIP, path: path, maxPixelSize: 320) }
            failed = image == nil
        }
    }
}
