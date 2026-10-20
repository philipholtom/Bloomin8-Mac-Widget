import AppKit
import Photos

/// Read-only access to the user's Photos library for the "Apple Photos"
/// sidebar entry: a flat list of image assets (newest first, no videos, no
/// album structure — see LibraryModel's `.applePhotos` case), plus
/// thumbnails and full-resolution exports on demand.
///
/// Kept out of Bloomin8Core and app-only: the widget has no Photos browser
/// today, so there's no reason for it to carry a Photos framework
/// dependency too.
enum PhotosLibrarySource {
    /// Requests access if not yet decided, otherwise just reports the
    /// current status. `.readWrite` (not `.readOnly`) matches the frame's
    /// scope elsewhere: on macOS this doesn't grant anything the browser
    /// doesn't already need — it's the same one system prompt either way.
    static func requestAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default:
            return false
        }
    }

    /// Every image asset in the library, newest first. `PHAsset.fetchAssets`
    /// is safe to call off the main thread — the caller runs this inside a
    /// detached task since even the fetch itself can take a moment against a
    /// large library. Also seeds `assetCache` so the grid's per-cell
    /// thumbnail/full-res requests (potentially tens of thousands of them)
    /// don't each have to re-run a `PHAsset.fetchAssets(withLocalIdentifiers:)`
    /// database lookup just to get back an object this call already had.
    static func fetchAllImageAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        assetCache.store(assets)
        return assets
    }

    // MARK: - Albums and "on this day"

    struct PhotoAlbum: Identifiable, Hashable {
        enum Kind { case smart, user, shared }
        /// `PHAssetCollection.localIdentifier`.
        let id: String
        let title: String
        let kind: Kind
        /// Number of still images in it (videos aren't sent to the frame).
        let count: Int
    }

    private static func imageOptions(newestFirst: Bool = true) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    /// The albums worth offering: Favourites and Recently Added, then the
    /// user's own albums and shared albums. Empty ones are left out. Safe off
    /// the main thread.
    static func fetchAlbums() -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []
        func collect(_ result: PHFetchResult<PHAssetCollection>, kind: PhotoAlbum.Kind) {
            result.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: imageOptions()).count
                guard count > 0 else { return }
                albums.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", kind: kind, count: count))
            }
        }
        for subtype in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumRecentlyAdded] {
            collect(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil), kind: .smart)
        }
        collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil), kind: .user)
        collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil), kind: .shared)
        return albums
    }

    /// Every image in one album, newest first.
    static func fetchImageAssets(inAlbum albumID: String) -> [PHAsset] {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else { return [] }
        return enumerate(PHAsset.fetchAssets(in: collection, options: imageOptions()))
    }

    /// Photos taken on `date`'s month and day in any earlier year (newest
    /// first), widened by `toleranceDays` either side. Fetches one narrow
    /// date range per year back to the oldest photo, rather than scanning the
    /// whole library.
    static func fetchOnThisDay(date: Date = Date(), toleranceDays: Int = 0) -> [PHAsset] {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.month, .day], from: date)
        let thisYear = calendar.component(.year, from: date)

        let oldestOptions = imageOptions(newestFirst: false)
        oldestOptions.fetchLimit = 1
        guard let oldest = PHAsset.fetchAssets(with: oldestOptions).firstObject?.creationDate else { return [] }
        let oldestYear = calendar.component(.year, from: oldest)
        guard oldestYear < thisYear else { return [] }

        var assets: [PHAsset] = []
        for year in stride(from: thisYear - 1, through: oldestYear, by: -1) {
            // Feb 29 in a non-leap year has no day to match.
            guard let day = calendar.date(from: DateComponents(year: year, month: parts.month, day: parts.day)),
                  calendar.component(.month, from: day) == parts.month,
                  let start = calendar.date(byAdding: .day, value: -toleranceDays, to: calendar.startOfDay(for: day)),
                  let end = calendar.date(byAdding: .day, value: toleranceDays + 1, to: calendar.startOfDay(for: day))
            else { continue }
            let options = imageOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
                PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate
            )
            assets.append(contentsOf: enumerate(PHAsset.fetchAssets(with: options)))
        }
        return assets
    }

    private static func enumerate(_ result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        assetCache.store(assets)
        return assets
    }

    /// The caption `displayName(for:)` would give, from just the ID.
    static func displayName(forAssetID assetID: String) -> String {
        resolveAsset(assetID).map(displayName(for:)) ?? assetID
    }

    /// A short label for the grid caption, since assets don't reliably expose
    /// a filename without a separate, per-asset resource lookup — too costly
    /// to do for every cell in a library that can run into the thousands.
    /// The creation date is what Photos.app itself shows on hover, so this
    /// matches that convention rather than inventing a new one.
    static func displayName(for asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return asset.localIdentifier }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let assetCache = AssetCache()

    /// Looks the asset up in `assetCache` first (populated by
    /// `fetchAllImageAssets()`, which the grid always runs before it can ask
    /// for a single thumbnail) and only falls back to a fresh database fetch
    /// if it's somehow missing — e.g. the browser wasn't the caller (a
    /// future feature reaching in with a bare ID).
    private static func resolveAsset(_ assetID: String) -> PHAsset? {
        if let cached = assetCache.asset(for: assetID) { return cached }
        return PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
    }

    /// A grid-sized preview for `assetID`, downloading from iCloud if the
    /// original isn't stored on this Mac. `.highQualityFormat` delivers
    /// exactly once (unlike `.opportunistic`, which can call back twice —
    /// a fast low-res pass then a better one — and would need extra
    /// bookkeeping to safely resume a continuation only once).
    static func thumbnail(assetID: String, maxPixelSize: Int) async -> NSImage? {
        guard let asset = resolveAsset(assetID) else { return nil }
        let targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The original image bytes for `assetID`, for Send to Frame — full
    /// resolution, orientation applied downstream by `loadUprightCGImage`.
    /// Downloads from iCloud if needed, so this can take longer than the
    /// thumbnail fetch above for a photo that isn't cached locally.
    static func fetchOriginalData(assetID: String) async -> Data? {
        guard let asset = resolveAsset(assetID) else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Plain lock-protected dictionary, not an actor: `fetchAllImageAssets()` is
/// a synchronous call (already running off the main thread inside a detached
/// task), and populating this from there shouldn't force it — or every
/// caller — through an `await`.
private final class AssetCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: PHAsset] = [:]

    func store(_ assets: [PHAsset]) {
        lock.lock()
        defer { lock.unlock() }
        for asset in assets { byID[asset.localIdentifier] = asset }
    }

    func asset(for id: String) -> PHAsset? {
        lock.lock()
        defer { lock.unlock() }
        return byID[id]
    }
}

/// Bounded thumbnail cache for the Photos grid, mirroring `ThumbnailStore`/
/// `DeviceThumbnailStore` in Bloomin8Core — same shape, kept as a separate
/// app-local type since it wraps `Photos` rather than a file path or an HTTP
/// fetch.
///
/// Concurrency is capped the same way `DeviceThumbnailStore` caps requests to
/// the frame's slow embedded HTTP server: without it, a library in the tens
/// of thousands scrolling past dozens of newly-visible grid cells at once
/// fires that many simultaneous `PHImageManager` requests, which was enough
/// to make photolibraryd fall behind and every cell sit on its spinner far
/// longer than a single thumbnail decode should ever take.
actor PhotosThumbnailStore {
    static let shared = PhotosThumbnailStore()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let maxConcurrent = 6
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func thumbnail(assetID: String, maxPixelSize: Int = 320) async -> NSImage? {
        let key = "\(assetID)#\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> {
            await self.acquireSlot()
            let image = await PhotosLibrarySource.thumbnail(assetID: assetID, maxPixelSize: maxPixelSize)
            await self.releaseSlot()
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private func acquireSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}
