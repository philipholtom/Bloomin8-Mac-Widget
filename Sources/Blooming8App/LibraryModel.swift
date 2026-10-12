import Blooming8Core
import AppKit
import Combine
import SwiftUI
import Photos
import os

/// What the sidebar can select, and the detail pane can show.
enum LibrarySource: Hashable {
    case currentPhoto
    case localFolder
    case browseFiles
    case museumCards
    case favorites
    case applePhotos
    case generated
    case gallery(String)

    var title: String {
        switch self {
        case .currentPhoto: return "On the Frame"
        case .localFolder: return "Local Folder"
        case .browseFiles: return "Browse Files"
        case .museumCards: return "Museum Cards"
        case .favorites: return "Favorites"
        case .applePhotos: return "Apple Photos"
        case .generated: return "Generated"
        case .gallery(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .currentPhoto: return "photo.on.rectangle.angled"
        case .localFolder: return "folder"
        case .browseFiles: return "folder.fill"
        case .museumCards: return "text.below.photo"
        case .favorites: return "star"
        case .applePhotos: return "photo.on.rectangle"
        case .generated: return "sparkles"
        case .gallery: return "rectangle.stack"
        }
    }
}

/// One browsable item: an image (local file, already on the frame, or a
/// local video). A video isn't sent directly — picking one opens a frame
/// picker (`VideoFramePickerSheet`) instead of Send to Frame.
struct LibraryItem: Identifiable, Hashable {
    enum Kind {
        case image
        case video
    }

    let id: String
    let url: URL?
    let devicePath: String?
    /// Set only for device-hosted items, alongside `devicePath` — carried
    /// separately rather than re-parsed out of the path string, since
    /// deleting an image needs the gallery name and bare filename apart.
    let galleryName: String?
    /// Set only for Photos-library items. Re-fetching the `PHAsset` by this
    /// ID when a thumbnail or full-resolution export is needed is cheap
    /// (a local database lookup), so items only carry the ID rather than
    /// the asset object itself.
    let photoAssetID: String?
    let name: String
    let kind: Kind

    init(localURL: URL, kind: Kind = .image) {
        self.id = localURL.path
        self.url = localURL
        self.devicePath = nil
        self.galleryName = nil
        self.photoAssetID = nil
        self.name = localURL.lastPathComponent
        self.kind = kind
    }

    init(devicePath: String, galleryName: String) {
        self.id = devicePath
        self.url = nil
        self.devicePath = devicePath
        self.galleryName = galleryName
        self.photoAssetID = nil
        self.name = (devicePath as NSString).lastPathComponent
        self.kind = .image
    }

    init(photoAssetID: String, name: String) {
        self.id = photoAssetID
        self.url = nil
        self.devicePath = nil
        self.galleryName = nil
        self.photoAssetID = photoAssetID
        self.name = name
        self.kind = .image
    }

    var isLocal: Bool { url != nil }
    var isVideo: Bool { kind == .video }
}

/// Backs the grid: owns the current source's item list and the work of
/// producing it. Enumeration and device fetches both happen off the main
/// thread — a 10k-file folder walk on the main actor freezes the window.
@MainActor
final class LibraryModel: ObservableObject {
    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "library")

    @Published var items: [LibraryItem] = []
    @Published var isLoading = false
    @Published var loadError: String?
    /// Set when a gallery only partly loaded: the photos that did arrive stay
    /// on screen, with this explaining why the rest isn't there.
    @Published var loadNotice: String?
    /// True while later pages of a gallery are still arriving.
    @Published var isLoadingMore = false
    /// The single item the inspector shows. Plain click sets this (and
    /// clears `selectedIDs` down to just that one item); it's kept separate
    /// from multi-select so the inspector always has one unambiguous subject.
    @Published var selection: LibraryItem.ID?
    /// Cmd/Shift-click multi-selection, for bulk favorite/delete. Always a
    /// superset containing `selection` when both are non-empty.
    @Published var selectedIDs: Set<LibraryItem.ID> = []
    @Published var searchText: String = ""
    private(set) var currentSource: LibrarySource?

    private let settings: AppSettings
    private let controller: PhotoController
    private let client = BloominClient()
    private var loadTask: Task<Void, Never>?

    /// Filenames per gallery, from the last successful fetch this session.
    /// Revisiting a gallery you've already opened redisplays instantly from
    /// here instead of re-walking the device's (slow, paginated) `/gallery`
    /// listing endpoint every single click — that listing fetch, not image
    /// data, was the actual source of the "reloads every time" delay, since
    /// DeviceThumbnailStore already caches the thumbnails themselves. Keyed
    /// by device IP + gallery name, not just gallery name — with multiple
    /// frame profiles, two different frames can each have a same-named
    /// gallery (e.g. both have a "Random"), and switching the active frame
    /// shouldn't show one frame's cached listing under the other's name.
    private var galleryListingCache: [String: [String]] = [:]

    private func galleryListingCacheKey(_ galleryName: String) -> String {
        "\(settings.deviceIP)#\(galleryName)"
    }

    init(settings: AppSettings, controller: PhotoController) {
        self.settings = settings
        self.controller = controller
    }

    var filteredItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedItem: LibraryItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// The actual selected items, in the same order they appear in the grid
    /// — used for bulk actions and for Shift-click range extension.
    var selectedItems: [LibraryItem] {
        filteredItems.filter { selectedIDs.contains($0.id) }
    }

    func load(_ source: LibrarySource) {
        Self.log.notice("load: \(source.title, privacy: .public)")
        loadTask?.cancel()
        currentSource = source
        selection = nil
        selectedIDs = []
        loadError = nil
        loadNotice = nil
        isLoadingMore = false

        switch source {
        case .currentPhoto, .generated, .browseFiles, .museumCards:
            // .browseFiles has its own view (FileBrowserView) with its own
            // folder-navigation state — it never routes through this grid.
            items = []
            isLoading = false

        case .localFolder:
            let path = settings.randomFolderPath.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                items = []
                loadError = "No folder chosen yet."
                return
            }
            loadLocal(folder: URL(fileURLWithPath: path))

        case .favorites:
            items = settings.favoriteImagePaths.map { LibraryItem(localURL: URL(fileURLWithPath: $0)) }
            isLoading = false

        case .applePhotos:
            loadApplePhotos()

        case .gallery(let name):
            loadGallery(named: name)
        }
    }

    /// Click-selection with Cmd (toggle) / Shift (range from the last
    /// anchor) support, matching the standard macOS Finder-grid convention.
    func selectItem(_ item: LibraryItem, extendWithCommand: Bool, extendWithShift: Bool) {
        if extendWithShift, let anchor = selection,
           let anchorIndex = filteredItems.firstIndex(where: { $0.id == anchor }),
           let targetIndex = filteredItems.firstIndex(where: { $0.id == item.id }) {
            let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            selectedIDs.formUnion(filteredItems[range].map(\.id))
            return
        }
        if extendWithCommand {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
                if selection == item.id { selection = selectedIDs.first }
            } else {
                selectedIDs.insert(item.id)
                selection = item.id
            }
            return
        }
        selection = item.id
        selectedIDs = [item.id]
    }

    /// Removes an item from `items` (and, for a gallery, its cache) after a
    /// successful delete on the frame — without waiting on a full reload.
    func removeItem(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        selectedIDs.remove(item.id)
        if selection == item.id { selection = nil }
        if let galleryName = item.galleryName {
            galleryListingCache[galleryListingCacheKey(galleryName)]?.removeAll { $0 == item.name }
        }
    }

    private func loadLocal(folder: URL) {
        isLoading = true
        items = []
        loadTask = Task {
            // Off the main actor: walking tens of thousands of files blocks
            // for seconds and would freeze the whole window.
            let (imageURLs, videoURLs) = await Task.detached(priority: .userInitiated) {
                (ImageFolder.enumerateImages(in: folder), VideoFolder.enumerateVideos(in: folder))
            }.value
            guard !Task.isCancelled else { return }
            let combined = imageURLs.map { LibraryItem(localURL: $0, kind: .image) }
                + videoURLs.map { LibraryItem(localURL: $0, kind: .video) }
            items = combined.sorted { $0.url!.path.localizedStandardCompare($1.url!.path) == .orderedAscending }
            Self.log.notice("load: local folder produced \(imageURLs.count) images, \(videoURLs.count) videos")
            isLoading = false
            if items.isEmpty { loadError = "No images or videos found under \(folder.path)." }
        }
    }

    /// Stale-while-revalidate, same idea as `galleryListingCache` below: a
    /// library with tens of thousands of photos takes a moment to enumerate
    /// and, more noticeably, to hand to SwiftUI as a fresh 30k+-item
    /// `ForEach` — not something worth re-paying on every single visit
    /// within a session just to pick up photos imported a moment ago.
    /// What the Apple Photos tab is showing: the whole library, photos taken
    /// on today's date in earlier years, or one album.
    enum PhotosChoice: Hashable {
        case all
        case onThisDay
        case album(id: String, title: String)

        var title: String {
            switch self {
            case .all: return "All Photos"
            case .onThisDay: return "On This Day"
            case .album(_, let title): return title
            }
        }
    }

    @Published private(set) var photosChoice: PhotosChoice = .all
    @Published private(set) var photosAlbums: [PhotosLibrarySource.PhotoAlbum] = []
    private var photosCaches: [PhotosChoice: [LibraryItem]] = [:]

    func selectPhotosChoice(_ choice: PhotosChoice) {
        photosChoice = choice
        if currentSource == .applePhotos { load(.applePhotos) }
    }

    private func loadApplePhotos() {
        let choice = photosChoice
        if let cached = photosCaches[choice] {
            items = cached
            isLoading = false
            loadError = cached.isEmpty ? emptyMessage(for: choice) : nil
        } else {
            isLoading = true
            items = []
        }

        loadTask = Task {
            guard await PhotosLibrarySource.requestAccess() else {
                isLoading = false
                loadError = "Photos access denied. Enable it for Blooming8 in System Settings → Privacy & Security → Photos."
                return
            }
            guard !Task.isCancelled else { return }

            // The album list refreshes every visit (albums come and go).
            let albums = await Task.detached(priority: .userInitiated) { PhotosLibrarySource.fetchAlbums() }.value
            guard !Task.isCancelled else { return }
            photosAlbums = albums

            var notice: String?
            let assets: [PHAsset] = await Task.detached(priority: .userInitiated) {
                switch choice {
                case .all:
                    return PhotosLibrarySource.fetchAllImageAssets()
                case .album(let id, _):
                    return PhotosLibrarySource.fetchImageAssets(inAlbum: id)
                case .onThisDay:
                    return PhotosLibrarySource.fetchOnThisDay()
                }
            }.value
            var found = assets
            if choice == .onThisDay, found.isEmpty {
                // Nothing on exactly this day — widen to a few days either side.
                found = await Task.detached(priority: .userInitiated) { PhotosLibrarySource.fetchOnThisDay(toleranceDays: 3) }.value
                if !found.isEmpty { notice = "Nothing from exactly this day — showing the three days either side." }
            }
            guard !Task.isCancelled else { return }

            let fresh = found.map { asset in
                LibraryItem(photoAssetID: asset.localIdentifier, name: PhotosLibrarySource.displayName(for: asset))
            }
            photosCaches[choice] = fresh
            items = fresh
            loadNotice = notice
            Self.log.notice("load: Apple Photos (\(choice.title, privacy: .public)) produced \(fresh.count) images")
            isLoading = false
            if items.isEmpty { loadError = emptyMessage(for: choice) }
        }
    }

    private func emptyMessage(for choice: PhotosChoice) -> String {
        switch choice {
        case .all: return "No photos found in your Photos library."
        case .onThisDay: return "No photos from this day in earlier years."
        case .album(_, let title): return "No photos in “\(title)”."
        }
    }

    /// Loads the current gallery again from the start.
    func reloadCurrentGallery() {
        if case .gallery(let name)? = currentSource { load(.gallery(name)) }
    }

    private func loadGallery(named name: String) {
        // Stale-while-revalidate: a cache hit shows instantly with no
        // spinner, then a fresh fetch runs silently underneath and updates
        // `items` again once it lands — so a gallery someone's added photos
        // to since your last visit still catches up, just without making
        // every single click wait on the device's slow listing endpoint.
        let cacheKey = galleryListingCacheKey(name)
        let hadCache: Bool
        if let cachedNames = galleryListingCache[cacheKey] {
            items = cachedNames.map { LibraryItem(devicePath: "/gallerys/\(name)/\($0)", galleryName: name) }
            isLoading = false
            loadError = items.isEmpty ? "This gallery is empty." : nil
            hadCache = true
        } else {
            isLoading = true
            items = []
            hadCache = false
        }

        loadTask = Task {
            var collected: [String] = []
            do {
                // The frame's listing gets slower with every page, so with
                // nothing cached the grid shows each page as it lands rather
                // than waiting for the last one.
                try await client.walkGalleryImages(ip: settings.deviceIP, gallery: name) { page in
                    guard !Task.isCancelled else { return }
                    collected.append(contentsOf: page)
                    if !hadCache {
                        items = collected.map { LibraryItem(devicePath: "/gallerys/\(name)/\($0)", galleryName: name) }
                        isLoading = false
                        isLoadingMore = true
                    }
                }
                guard !Task.isCancelled else { return }
                galleryListingCache[cacheKey] = collected
                items = collected.map { LibraryItem(devicePath: "/gallerys/\(name)/\($0)", galleryName: name) }
                isLoading = false
                isLoadingMore = false
                loadError = items.isEmpty ? "This gallery is empty." : nil
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                isLoadingMore = false
                // Cached data is already on screen — a background refresh
                // failing (the frame went to sleep, a request timed out)
                // shouldn't replace it with an error the user didn't ask for.
                guard !hadCache else { return }
                if collected.isEmpty {
                    loadError = error.localizedDescription
                } else {
                    loadNotice = "Showing the first \(collected.count) — the frame stopped answering before the rest loaded."
                }
            }
        }
    }
}
