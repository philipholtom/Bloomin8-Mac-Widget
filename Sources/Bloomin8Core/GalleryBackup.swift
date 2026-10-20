import Foundation

/// Where a backup run has got to, for the progress display.
public struct BackupProgress {
    public var gallery: String
    public var galleryIndex: Int
    public var galleryCount: Int
    public var fileIndex: Int
    public var fileCount: Int
    public var downloaded: Int
    public var skipped: Int
    public var failed: Int
}

public struct BackupResult {
    public var galleries: Int
    public var downloaded: Int
    public var skipped: Int
    public var failed: Int
    public var cancelled: Bool
    /// The folder holding this frame's backup (`…/Blooming8 Backup/<frame>`).
    public var folder: URL
}

extension PhotoController {
    /// Copies every photo in the named galleries from the frame to this Mac:
    /// `<destination>/Blooming8 Backup/<frame name>/<gallery>/<file>`. Safe to
    /// run again into the same place — photos already there are skipped, so a
    /// repeat run only fetches what's new. A photo that fails is counted and
    /// the run carries on; cancelling the surrounding `Task` stops it cleanly
    /// after the current photo.
    public func backupGalleries(
        _ names: [String],
        to destination: URL,
        progress: @MainActor (BackupProgress) -> Void
    ) async -> BackupResult {
        let frameFolder = destination
            .appendingPathComponent("Blooming8 Backup", isDirectory: true)
            .appendingPathComponent(Self.pathSafe(settings.frameProfiles.first(where: { $0.id == settings.activeFrameProfileID })?.name ?? "Frame"), isDirectory: true)
        var result = BackupResult(galleries: 0, downloaded: 0, skipped: 0, failed: 0, cancelled: false, folder: frameFolder)
        var counts: [String: Int] = [:]

        isBusy = true
        defer { isBusy = false }
        let fileManager = FileManager.default

        for (galleryIndex, gallery) in names.enumerated() {
            if Task.isCancelled { result.cancelled = true; break }
            var progressNow = BackupProgress(gallery: gallery, galleryIndex: galleryIndex + 1, galleryCount: names.count, fileIndex: 0, fileCount: 0, downloaded: result.downloaded, skipped: result.skipped, failed: result.failed)
            progress(progressNow)

            var photoNames: [String] = []
            do {
                try await client.walkGalleryImages(ip: settings.deviceIP, gallery: gallery) { photoNames.append(contentsOf: $0) }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                // Keep whatever listed before the failure; the rest of the
                // gallery is picked up by the next run.
                if photoNames.isEmpty { result.failed += 1; continue }
            }
            if Task.isCancelled { result.cancelled = true; break }

            let galleryFolder = frameFolder.appendingPathComponent(Self.pathSafe(gallery), isDirectory: true)
            try? fileManager.createDirectory(at: galleryFolder, withIntermediateDirectories: true)
            result.galleries += 1
            counts[gallery] = photoNames.count
            progressNow.fileCount = photoNames.count

            for (fileIndex, photo) in photoNames.enumerated() {
                if Task.isCancelled { result.cancelled = true; break }
                progressNow.fileIndex = fileIndex + 1
                let target = galleryFolder.appendingPathComponent(Self.pathSafe(photo))

                let existingSize = (try? fileManager.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
                if existingSize > 0 {
                    result.skipped += 1
                } else {
                    var saved = false
                    for _ in 0..<2 where !saved && !Task.isCancelled {
                        if let data = try? await client.fetchImageData(ip: settings.deviceIP, path: "/gallerys/\(gallery)/\(photo)"), !data.isEmpty {
                            saved = (try? data.write(to: target, options: .atomic)) != nil
                        }
                    }
                    if saved { result.downloaded += 1 } else if !Task.isCancelled { result.failed += 1 }
                }
                progressNow.downloaded = result.downloaded
                progressNow.skipped = result.skipped
                progressNow.failed = result.failed
                progress(progressNow)
            }
            if result.cancelled { break }
        }
        if Task.isCancelled { result.cancelled = true }

        // A small record next to the photos of what was backed up and when.
        let info: [String: Any] = [
            "frame": frameFolder.lastPathComponent,
            "lastRun": ISO8601DateFormatter().string(from: Date()),
            "photosPerGallery": counts
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? fileManager.createDirectory(at: frameFolder, withIntermediateDirectories: true)
            try? data.write(to: frameFolder.appendingPathComponent("backup-info.json"), options: .atomic)
        }

        let summary = "Backed up \(result.galleries) galler\(result.galleries == 1 ? "y" : "ies"): \(result.downloaded) new, \(result.skipped) already there"
            + (result.failed > 0 ? ", \(result.failed) failed" : "")
            + (result.cancelled ? " (stopped early)" : "")
        statusText = summary + "."
        logActivity(summary, success: result.failed == 0 && !result.cancelled)
        return result
    }

    /// A string safe to use as one path component: no slashes or colons.
    public nonisolated static func pathSafe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/:\\\\]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
