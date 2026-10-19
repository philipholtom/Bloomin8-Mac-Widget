import Foundation
import AppKit
import CryptoKit

/// Recursive image-file discovery on the local disk, shared by the widget's
/// random picker and the app's folder browser.
public enum ImageFolder {
    public static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff", "tif", "webp"
    ]

    /// Walks `folder` recursively and returns every image file found. Skips
    /// hidden files and package contents (an .app or .photoslibrary would
    /// otherwise contribute thousands of irrelevant images).
    ///
    /// Blocking and potentially slow over tens of thousands of files, so call
    /// it off the main thread — it is `nonisolated` precisely so callers can.
    public static func enumerateImages(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator
        where imageFileExtensions.contains(url.pathExtension.lowercased()) {
            urls.append(url)
        }
        return urls
    }
}

/// Bounded, off-main-thread thumbnail cache for grids over large image sets.
///
/// Decoding a full-size photo costs tens of milliseconds; a grid scrolling
/// through thousands of them has to decode small and decode once, or it
/// stutters badly. Keyed by path plus pixel size so the same file can be
/// cached at more than one size.
public actor ThumbnailStore {
    public static let shared = ThumbnailStore()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// In-flight loads, so a cell that scrolls off and back on doesn't kick
    /// off a second decode of the same file.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    public init() {}

    public func thumbnail(for url: URL, maxPixelSize: Int = 320) async -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            guard let cgImage = loadUprightCGImage(at: url, maxPixelSize: maxPixelSize) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    public func clear() {
        cache.removeAllObjects()
    }
}

/// Fetches and caches thumbnails for images already stored on the frame.
///
/// There's no dedicated thumbnail endpoint on the device — confirmed against
/// ARPOBOT's own Home Assistant integration, which fetches full-size images
/// and caches the raw bytes client-side rather than requesting a smaller
/// version, i.e. the same constraint this store works under. Every thumbnail
/// here is a real fetch of the full-size JPEG, downscaled and cached on this
/// side; concurrency is capped so scrolling a gallery grid can't fire dozens
/// of simultaneous requests at the frame's embedded HTTP server, which has
/// shown itself to be slow even for a single request (observed request
/// timeouts against it during development).
public actor DeviceThumbnailStore {
    public static let shared = DeviceThumbnailStore()

    private let client = BloominClient()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// At most this many fetches run at once, regardless of how many grid
    /// cells ask for a thumbnail while scrolling.
    private let maxConcurrent = 2
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Backs the in-memory cache with a disk cache under this Mac's own
    /// Caches directory, so a gallery browsed in an earlier app launch still
    /// shows thumbnails instantly instead of re-fetching every full-size
    /// JPEG from the frame's slow embedded HTTP server again. The in-memory
    /// `cache` above is cleared on quit; this survives it.
    private static let diskCacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.pholtom.blooming8/DeviceThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Evicts oldest files once the cache exceeds this size, rather than
    /// growing unbounded across a large library browsed over many sessions.
    private static let maxDiskCacheBytes = 200 * 1024 * 1024

    public init() {}

    public func thumbnail(ip: String, path: String, maxPixelSize: Int = 320) async -> NSImage? {
        let key = "\(ip)#\(path)#\(maxPixelSize)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }
        let diskURL = Self.diskCacheURL(for: key)
        if let diskData = try? Data(contentsOf: diskURL),
           let cgImage = loadUprightCGImage(data: diskData, maxPixelSize: maxPixelSize) {
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key as NSString)
            return image
        }

        let task = Task<NSImage?, Never> { [client] in
            await self.acquireSlot()
            let image: NSImage? = await {
                guard let data = try? await client.fetchImageData(ip: ip, path: path),
                      let cgImage = loadUprightCGImage(data: data, maxPixelSize: maxPixelSize)
                else { return nil }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                if let thumbnailData = ImageCanvas.jpegData(image, quality: 0.8) {
                    try? thumbnailData.write(to: diskURL)
                    Self.evictOldestIfOverBudget()
                }
                return image
            }()
            await self.releaseSlot()
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// A thumbnail already on this Mac — in memory or on disk, at any of
    /// `sizes` — without asking the frame. The caches are keyed by size, so a
    /// screen that wants "any copy will do" (a small preview that can reuse
    /// what the gallery grid or the museum cards already fetched) tries each
    /// size in turn. Works while the frame is asleep.
    public func cachedThumbnail(ip: String, path: String, sizes: [Int]) -> NSImage? {
        for size in sizes {
            let key = "\(ip)#\(path)#\(size)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            if let diskData = try? Data(contentsOf: Self.diskCacheURL(for: key)),
               let cgImage = loadUprightCGImage(data: diskData, maxPixelSize: size) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                cache.setObject(image, forKey: key as NSString)
                return image
            }
        }
        return nil
    }

    public func clear() {
        cache.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.diskCacheDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The current total size of the on-disk thumbnail cache, for display
    /// next to the "Clear" button in Settings.
    public static func diskCacheSizeBytes() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private static func diskCacheURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent("\(hash).jpg")
    }

    /// Deletes oldest-modified files first until the cache is back under
    /// budget. Runs after every new write rather than on a timer — thumbnail
    /// writes are infrequent enough (one per newly-seen photo, capped at
    /// `maxConcurrent` in flight) that scanning the directory each time costs
    /// nothing noticeable in practice.
    private static func evictOldestIfOverBudget() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        let entries = files.map { url -> (url: URL, size: Int, date: Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxDiskCacheBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > maxDiskCacheBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
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
