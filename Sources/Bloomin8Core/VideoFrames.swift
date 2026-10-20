import AVFoundation
import AppKit

/// Recursive video-file discovery, alongside `ImageFolder`'s image scan —
/// used by the app's Local Folder browser to surface movies you can pull a
/// screenshot from, not by the widget's random-photo picker.
public enum VideoFolder {
    /// Formats AVFoundation decodes reliably without extra codecs on macOS.
    /// Deliberately narrower than the image extension list — an unsupported
    /// container would just fail frame extraction with nothing useful to
    /// show, so it's better not to list it as a video at all.
    public static let videoFileExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func enumerateVideos(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator
        where videoFileExtensions.contains(url.pathExtension.lowercased()) {
            urls.append(url)
        }
        return urls
    }
}

/// Pulls still frames out of a local video file, as a coarse alternative to a
/// full scrubbing player: grab a handful of frames spread across the video
/// and let the caller offer them as a picker grid instead of a timeline.
public enum VideoFrameExtractor {
    private static func makeGenerator(for url: URL, maxPixelSize: CGFloat) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Zero tolerance forces AVFoundation to decode the *exact* requested
        // frame, which is fragile — on some videos (sparse keyframes, an
        // unusual structure near the start) it fails outright for certain
        // timestamps rather than just being slow. Observed directly: the
        // frame picker's grid would end up with only some slots populated,
        // and it was disproportionately the earlier ones that failed. A
        // half-second tolerance lets the generator snap to whatever nearby
        // frame it can decode reliably — plenty precise for "pick roughly
        // this moment," which is all this picker ever needed.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// Attempts a single frame at `time`, retrying at a couple of small
    /// offsets if the exact point fails — a slot's chosen instant can land
    /// on something the decoder can't produce, and giving up on the whole
    /// slot after one failure was exactly what caused a video to sometimes
    /// hand back fewer than `count` frames, silently, with rows in the
    /// picker grid that were never actually there rather than just
    /// unclickable.
    private static func extractOneFrame(
        generator: AVAssetImageGenerator,
        around time: CMTime,
        slotBounds: ClosedRange<Double>
    ) -> NSImage? {
        let attempts = [time.seconds, slotBounds.lowerBound, slotBounds.upperBound]
        for seconds in attempts {
            let attemptTime = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: attemptTime, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return nil
    }

    /// `count` frames spread across the video, skipping a small margin at
    /// the very start and end — often a black frame or a fade. The video is
    /// divided into `count` equal-width slots and one frame is picked at a
    /// random point within each — not at a fixed position within it — so a
    /// repeat call (the frame picker's "Next" button) returns a genuinely
    /// different set of moments instead of the exact same 9 frames, while
    /// each set still covers the whole video rather than clustering, the
    /// way a fully random draw could.
    public static func extractFrames(from url: URL, count: Int = 9, maxPixelSize: CGFloat = 800) async -> [NSImage] {
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isValid, duration.seconds > 0
        else { return [] }

        let totalSeconds = duration.seconds
        let margin = totalSeconds * 0.05
        let usableRange = max(totalSeconds - margin * 2, 0.1)
        let slotWidth = usableRange / Double(count)
        let slots: [(target: CMTime, bounds: ClosedRange<Double>)] = (0..<count).map { i in
            let slotStart = margin + Double(i) * slotWidth
            let slotEnd = slotStart + slotWidth
            // Stays off both edges of its slot so consecutive frames can't
            // land right next to each other by chance.
            let offset = Double.random(in: 0.15...0.85) * slotWidth
            let target = CMTime(seconds: slotStart + offset, preferredTimescale: 600)
            return (target, slotStart...slotEnd)
        }

        // AVAssetImageGenerator's per-frame call is synchronous and blocking
        // (a pre-async/await API); Task.detached keeps that off the main
        // actor so pulling several frames doesn't freeze the window.
        return await Task.detached(priority: .userInitiated) {
            let generator = makeGenerator(for: url, maxPixelSize: maxPixelSize)
            return slots.compactMap { slot in
                extractOneFrame(generator: generator, around: slot.target, slotBounds: slot.bounds)
            }
        }.value
    }

    /// One frame at a random point in the video — for a fully automatic
    /// "surprise me" pick with no picker grid to choose from, unlike
    /// `extractFrames`. Uses the same start/end margin as `extractFrames` so
    /// the random draw can't land on the black frame that's common right at
    /// either edge.
    public static func randomFrame(from url: URL, maxPixelSize: CGFloat = 1600) async -> NSImage? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isValid, duration.seconds > 0
        else { return nil }

        let totalSeconds = duration.seconds
        let margin = totalSeconds * 0.05
        let usableRange = max(totalSeconds - margin * 2, 0.1)
        let seconds = margin + Double.random(in: 0...usableRange)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        return await Task.detached(priority: .userInitiated) {
            let generator = makeGenerator(for: url, maxPixelSize: maxPixelSize)
            return extractOneFrame(generator: generator, around: time, slotBounds: margin...(margin + usableRange))
        }.value
    }

    /// One quick frame for a grid thumbnail — near the start but not at
    /// time zero, which is frequently black.
    public static func previewFrame(from url: URL, maxPixelSize: CGFloat = 400) async -> NSImage? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration),
              duration.isValid, duration.seconds > 0
        else { return nil }
        let seconds = min(duration.seconds * 0.1, 3)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        return await Task.detached(priority: .utility) {
            let generator = makeGenerator(for: url, maxPixelSize: maxPixelSize)
            return extractOneFrame(generator: generator, around: time, slotBounds: 0...max(seconds, 0.1))
        }.value
    }
}
