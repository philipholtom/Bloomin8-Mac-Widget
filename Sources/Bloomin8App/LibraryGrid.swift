import Bloomin8Core
import AppKit
import SwiftUI

struct LibraryGrid: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController
    let thumbnailSize: Double

    /// A video the user tapped, awaiting the frame-picker sheet. Videos
    /// aren't sent directly — there's no single "the" frame to upload — so a
    /// tap here bypasses `library.selection`/Send entirely.
    @State private var videoForFramePicker: LibraryItem?
    /// Items awaiting the "delete from frame" confirmation — non-nil shows
    /// the alert. A destructive, one-way action on the device, so it's
    /// confirmed regardless of whether it's one image or a whole selection.
    @State private var pendingDeletion: [LibraryItem]?
    @State private var pendingMove: [LibraryItem]?
    @State private var cropTarget: LibraryItem?
    @State private var isDropTargeted = false
    @State private var showPhotosPicker = false

    /// The gallery currently being browsed, if any — used both to know
    /// whether a drop here means "upload into this gallery" and to refresh
    /// the listing afterward.
    private var currentGalleryName: String? {
        if case .gallery(let name) = library.currentSource { return name }
        return nil
    }

    var body: some View {
        Group {
            if library.isLoading {
                loading
            } else if let error = library.loadError, library.items.isEmpty {
                message(error, symbol: "exclamationmark.triangle")
            } else if library.filteredItems.isEmpty {
                message("Nothing matches “\(library.searchText)”.", symbol: "magnifyingglass")
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Filter by filename")
        .safeAreaInset(edge: .top, spacing: 0) {
            if library.currentSource == .applePhotos { photosHeader }
        }
        .safeAreaInset(edge: .bottom) { countBar }
        .sheet(isPresented: $showPhotosPicker) {
            LocalFolderCandidatePickerSheet(controller: controller, source: photosPickerSource)
        }
        .sheet(item: $videoForFramePicker) { item in
            if let url = item.url {
                VideoFramePickerSheet(videoURL: url, controller: controller)
            }
        }
        .sheet(item: $cropTarget) { item in
            if let url = item.url {
                CropSheet(
                    imageURL: url,
                    canvasAspect: Double(controller.settings.renderWidth) / Double(controller.settings.renderHeight),
                    settings: settings
                ) { region in
                    Task { await controller.sendCropped(fileURL: url, crop: region) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } })) {
            MoveToGallerySheet(
                items: pendingMove ?? [],
                controller: controller,
                excludedGalleryName: currentGalleryName
            ) { moved in
                for item in moved { library.removeItem(item) }
            }
        }
        .alert(
            deletionAlertTitle,
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                let items = pendingDeletion ?? []
                pendingDeletion = nil
                Task { await deleteFromFrame(items) }
            }
        } message: {
            Text("This removes \(pendingDeletion?.count == 1 ? "this image" : "these images") from the frame. This can't be undone.")
        }
        .overlay {
            if isDropTargeted, currentGalleryName != nil {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Drop to upload to '\(currentGalleryName ?? "")'", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .padding(12)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var grid: some View {
        // Grouped-by-folder only for Local Folder: it's the only source with
        // real folder structure to show (a device gallery or Favorites is
        // inherently flat), and it's the source people actually browse
        // recursively, which is what made "which folder am I looking at"
        // worth solving.
        if case .localFolder = library.currentSource {
            groupedGrid
        } else {
            flatGrid
        }
    }

    private var flatGrid: some View {
        ScrollView {
            // LazyVGrid only materialises visible cells, and each cell loads
            // its own thumbnail on appear — the combination is what makes a
            // folder of 10k+ photos scroll without stalling.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 10)],
                spacing: 10
            ) {
                ForEach(library.filteredItems) { item in
                    cell(for: item)
                }
            }
            .padding(12)
        }
    }

    /// One entry per containing folder. Grouped with a dictionary keyed by
    /// folder path rather than by scanning for contiguous runs — a folder
    /// with both its own files and a subfolder doesn't stay contiguous
    /// after sorting by full path (confirmed directly: "Photos/z.jpg" sorts
    /// *after* "Photos/Sub/b.jpg", since natural sort compares "z" against
    /// "S" character-by-character with no awareness that one is a deeper
    /// path), which would otherwise split "Photos" into two separate groups
    /// with the header repeating. Still a single forward pass plus a sort of
    /// just the distinct folder paths (far fewer than the item count) — this
    /// runs once when the item list or filter changes, not per cell or per
    /// scroll frame, so it isn't part of what makes the grid fast.
    private struct FolderGroup: Identifiable {
        let id: String
        let label: String
        let items: [LibraryItem]
    }

    private var folderGroups: [FolderGroup] {
        let rootPath = settings.randomFolderPath.trimmingCharacters(in: .whitespaces)
        var itemsByFolder: [String: [LibraryItem]] = [:]
        for item in library.filteredItems {
            let folderPath = item.url?.deletingLastPathComponent().path ?? ""
            itemsByFolder[folderPath, default: []].append(item)
        }
        return itemsByFolder.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folderPath in
                FolderGroup(id: folderPath, label: folderLabel(for: folderPath, root: rootPath), items: itemsByFolder[folderPath] ?? [])
            }
    }

    private func folderLabel(for folderPath: String, root: String) -> String {
        guard folderPath.hasPrefix(root) else { return (folderPath as NSString).lastPathComponent }
        let relative = folderPath.dropFirst(root.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relative.isEmpty {
            return (root as NSString).lastPathComponent
        }
        return relative
    }

    private var groupedGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(folderGroups) { group in
                    Section {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(group.items) { item in
                                cell(for: item)
                            }
                        }
                        .padding(.horizontal, 12)
                    } header: {
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func cell(for item: LibraryItem) -> some View {
        LibraryCell(
            item: item,
            size: thumbnailSize,
            isSelected: library.selectedIDs.contains(item.id),
            isCurrentOnFrame: item.devicePath != nil && item.devicePath == controller.currentImagePath,
            settings: settings
        )
        .onTapGesture {
            if item.isVideo {
                videoForFramePicker = item
            } else {
                let flags = NSEvent.modifierFlags
                library.selectItem(
                    item,
                    extendWithCommand: flags.contains(.command),
                    extendWithShift: flags.contains(.shift)
                )
            }
        }
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: LibraryItem) -> some View {
        // Right-clicking an item that's part of a larger active selection
        // acts on the whole selection, matching Finder; otherwise it acts on
        // just the item under the pointer.
        let isBulk = library.selectedIDs.contains(item.id) && library.selectedIDs.count > 1
        let targets = isBulk ? library.selectedItems : [item]

        if item.isVideo {
            Button("Pick a Frame to Send…") { videoForFramePicker = item }
        } else if isBulk {
            Button("Send \(targets.count) to Frame") {
                for target in targets { send(target) }
            }
        } else {
            Button("Send to Frame") { send(item) }
            if item.url != nil {
                Button("Crop & Send…") { cropTarget = item }
            }
        }

        let deletableTargets = targets.filter { $0.galleryName != nil }
        if !deletableTargets.isEmpty {
            Divider()
            Button(deletableTargets.count == 1 ? "Move to Gallery…" : "Move \(deletableTargets.count) to Gallery…") {
                pendingMove = deletableTargets
            }
            Button(deletableTargets.count == 1 ? "Delete from Frame…" : "Delete \(deletableTargets.count) from Frame…", role: .destructive) {
                pendingDeletion = deletableTargets
            }
        }

        if let url = item.url, !isBulk {
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            if !item.isVideo {
                Divider()
                if settings.favoriteImagePaths.contains(url.path) {
                    Button("Remove from Favorites", role: .destructive) {
                        settings.favoriteImagePaths.removeAll { $0 == url.path }
                    }
                } else {
                    Button("Add to Favorites") {
                        settings.favoriteImagePaths.append(url.path)
                    }
                }
            }
        } else if isBulk {
            let favoritable = targets.filter { $0.url != nil && !$0.isVideo }
            if !favoritable.isEmpty {
                Divider()
                Button("Add \(favoritable.count) to Favorites") {
                    for target in favoritable {
                        guard let path = target.url?.path, !settings.favoriteImagePaths.contains(path) else { continue }
                        settings.favoriteImagePaths.append(path)
                    }
                }
            }
        }
    }

    private var deletionAlertTitle: String {
        let count = pendingDeletion?.count ?? 0
        return count == 1 ? "Delete this image?" : "Delete \(count) images?"
    }

    private func deleteFromFrame(_ items: [LibraryItem]) async {
        for item in items {
            guard let gallery = item.galleryName else { continue }
            let ok = await controller.deleteDeviceImage(gallery: gallery, filename: item.name)
            if ok { library.removeItem(item) }
        }
    }

    private func send(_ item: LibraryItem) {
        Task {
            if let url = item.url {
                controller.prepareBrowsedImage(url: url)
                // prepareBrowsedImage renders off the main thread and parks the
                // result in localFolderCandidates; send the one it produced.
                while controller.localFolderCandidates.isEmpty && controller.isBusy {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let candidate = controller.localFolderCandidates.first {
                    await controller.confirmLocalFolderCandidate(candidate)
                    controller.cancelLocalFolderCandidate()
                }
            } else if let devicePath = item.devicePath {
                await controller.showImageAtPath(devicePath)
            } else if let assetID = item.photoAssetID {
                guard let data = await PhotosLibrarySource.fetchOriginalData(assetID: assetID) else { return }
                controller.preparePhotosLibraryImage(data: data, displayName: item.name, assetID: assetID)
                if let candidate = controller.localFolderCandidates.first {
                    await controller.confirmLocalFolderCandidate(candidate)
                    controller.cancelLocalFolderCandidate()
                }
            }
        }
    }

    /// Drops onto the grid upload into whichever device gallery is currently
    /// open — dropping onto Local Folder or Favorites (both read from disk,
    /// not upload targets) is a no-op.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let galleryName = currentGalleryName else { return false }
        guard !providers.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let url = await loadFileURL(provider) else { continue }
                if ImageFolder.imageFileExtensions.contains(url.pathExtension.lowercased()) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await controller.uploadPhotos(urls: urls, gallery: galleryName)
            library.load(.gallery(galleryName))
        }
        return true
    }

    private func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Scanning…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Apple Photos header

    /// The album menu and Random 3 button shown above the Apple Photos grid.
    private var photosHeader: some View {
        HStack(spacing: 10) {
            Menu {
                photosChoiceButton(.all, symbol: "photo.on.rectangle")
                photosChoiceButton(.onThisDay, symbol: "calendar")
                photosAlbumSection(title: nil, kind: .smart)
                photosAlbumSection(title: "My Albums", kind: .user)
                photosAlbumSection(title: "Shared Albums", kind: .shared)
            } label: {
                Label(library.photosChoice.title, systemImage: library.photosChoice == .onThisDay ? "calendar" : "photo.stack")
            }
            .fixedSize()

            Button {
                showPhotosPicker = true
            } label: {
                Label("Random 3", systemImage: "shuffle")
            }
            .disabled(controller.isBusy)
            .help("Pick 3 random photos from \(library.photosChoice.title) to choose from")

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func photosChoiceButton(_ choice: LibraryModel.PhotosChoice, symbol: String) -> some View {
        Button {
            library.selectPhotosChoice(choice)
        } label: {
            if library.photosChoice == choice {
                Label(choice.title, systemImage: "checkmark")
            } else {
                Text(choice.title)
            }
        }
    }

    @ViewBuilder
    private func photosAlbumSection(title: String?, kind: PhotosLibrarySource.PhotoAlbum.Kind) -> some View {
        let albums = library.photosAlbums.filter { $0.kind == kind }
        if !albums.isEmpty {
            Divider()
            if let title { Text(title) }
            ForEach(albums) { album in
                photosChoiceButton(.album(id: album.id, title: album.title), symbol: "rectangle.stack")
                    .help("\(album.count) photos")
            }
        }
    }

    private var photosPickerSource: LocalFolderCandidatePickerSheet.Source {
        switch library.photosChoice {
        case .all: return .photosAlbum(id: nil, title: "Photos")
        case .onThisDay: return .photosOnThisDay
        case .album(let id, let title): return .photosAlbum(id: id, title: title)
        }
    }

    private var countBar: some View {
        HStack(spacing: 8) {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if library.isLoadingMore {
                ProgressView().controlSize(.small)
                Text("Loading more…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = library.loadNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if case .gallery? = library.currentSource {
                    Button("Retry") { library.reloadCurrentGallery() }
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countLabel: String {
        if library.selectedIDs.count > 1 {
            return "\(library.selectedIDs.count) selected"
        }
        let shown = library.filteredItems.count
        let total = library.items.count
        let videoCount = library.items.filter(\.isVideo).count
        let imageCount = total - videoCount
        let videoSuffix = videoCount > 0 ? ", \(videoCount) video\(videoCount == 1 ? "" : "s")" : ""
        if shown == total {
            return "\(imageCount) image\(imageCount == 1 ? "" : "s")\(videoSuffix)"
        }
        return "\(shown) of \(total) shown\(videoSuffix)"
    }
}

/// A single grid cell. Loads its thumbnail on appear via the shared store, so
/// scrolling past a cell never blocks and revisiting one is cached.
private struct LibraryCell: View {
    let item: LibraryItem
    let size: Double
    let isSelected: Bool
    let isCurrentOnFrame: Bool
    @ObservedObject var settings: AppSettings

    @State private var image: NSImage?
    @State private var didAttemptLoad = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))

                if let image {
                    PrivacyImage(image, settings: settings, gallery: item.galleryName, isLocalFile: item.isLocal)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .privacyBlur(settings: settings, gallery: item.galleryName, isLocalFile: item.isLocal)
                } else if didAttemptLoad {
                    Image(systemName: item.isVideo ? "film" : (item.isLocal ? "questionmark.square.dashed" : "photo"))
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }

                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.4))
                }

                if isCurrentOnFrame {
                    Text("ON FRAME")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(height: size)
            .clipped()
            .overlay(
                // Selection (blue) takes priority when both apply — a
                // green ring alone was easy to miss entirely: an 8pt corner
                // badge on a small thumbnail among dozens of others. A full
                // border around the cell is visible at a glance without
                // having to already know where to look.
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : (isCurrentOnFrame ? Color.green : .clear), lineWidth: 3)
            )

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .help(item.url?.path ?? item.devicePath ?? item.name)
        .task(id: item.id) {
            guard image == nil else { return }
            if item.isVideo, let url = item.url {
                image = await VideoFrameExtractor.previewFrame(from: url, maxPixelSize: 400)
            } else if let url = item.url {
                image = await ThumbnailStore.shared.thumbnail(for: url, maxPixelSize: 400)
            } else if let devicePath = item.devicePath {
                // The frame has no thumbnail endpoint, so this is a real
                // full-size fetch — DeviceThumbnailStore caps how many run
                // at once so a big gallery doesn't hammer the frame's HTTP
                // server while the grid scrolls past dozens of cells.
                image = await DeviceThumbnailStore.shared.thumbnail(
                    ip: settings.deviceIP,
                    path: devicePath,
                    maxPixelSize: 400
                )
            } else if let assetID = item.photoAssetID {
                image = await PhotosThumbnailStore.shared.thumbnail(assetID: assetID, maxPixelSize: 400)
            }
            didAttemptLoad = true
        }
    }

    private var isFavorite: Bool {
        guard let path = item.url?.path else { return false }
        return settings.favoriteImagePaths.contains(path)
    }
}
