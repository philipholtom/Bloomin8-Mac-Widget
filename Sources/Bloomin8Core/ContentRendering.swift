import AppKit
import ImageIO

/// Shared drawing helpers for ContentSource implementations, ported from the
/// PIL-based rendering in the original Python scripts. Uses a top-left
/// origin (Y increases downward) so coordinates match the Python code
/// almost 1:1.
public enum ImageCanvas {
    public static func render(width: Int, height: Int, draw: () -> Void) -> NSImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Flip the context's own coordinate system to top-left origin via its
        // CTM, rather than relying on NSGraphicsContext's "flipped" flag —
        // that flag isn't consistently honored by every AppKit drawing API
        // for an off-screen bitmap context with no backing NSView (confirmed
        // by direct testing: shapes/positions came out mirrored top-to-bottom
        // with `flipped: true` alone). A real CTM flip is unambiguous and
        // works the same for every shape-drawing call. Text still needs its
        // own local counter-flip — see drawCentered below.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = nsContext
        draw()
        NSGraphicsContext.current = previous

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Baseline (non-progressive) JPEG at the given quality, matching the
    /// Python scripts' `quality=95, progressive=False` output.
    public static func jpegData(_ image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

/// Draws `text` horizontally centered on a canvas of `canvasWidth`, at
/// vertical position `y` (top-left origin, matching ImageCanvas's flipped
/// context) — the recurring "centered label" pattern across content sources.
///
/// `NSString.draw(at:)` draws glyphs in their native (Y-up) orientation
/// regardless of the ambient context's flip — inside ImageCanvas's flipped
/// context that means glyphs render upside down unless counter-flipped
/// locally, which is what this does (confirmed by direct visual testing).
public func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat, canvasWidth: Int) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let nsText = text as NSString
    let size = nsText.size(withAttributes: attrs)
    let origin = NSPoint(x: (CGFloat(canvasWidth) - size.width) / 2, y: y)

    guard let cgContext = NSGraphicsContext.current?.cgContext else {
        nsText.draw(at: origin, withAttributes: attrs)
        return
    }
    cgContext.saveGState()
    cgContext.translateBy(x: origin.x, y: origin.y)
    cgContext.scaleBy(x: 1, y: -1)
    nsText.draw(at: .zero, withAttributes: attrs)
    cgContext.restoreGState()
}

/// Draws `image` filling `rect` (top-left origin, matching ImageCanvas's
/// flipped context). Like text, `NSImage.draw(in:)` composites its content
/// in native (Y-up) orientation regardless of the ambient context's flip —
/// without this local counter-flip, the image renders upside down inside
/// an otherwise correctly-positioned rect (confirmed by direct visual
/// testing, same as the text case above).
public func drawImage(_ image: NSImage, in rect: NSRect) {
    guard let cgContext = NSGraphicsContext.current?.cgContext else {
        image.draw(in: rect)
        return
    }
    cgContext.saveGState()
    cgContext.translateBy(x: rect.minX, y: rect.minY)
    cgContext.scaleBy(x: 1, y: -1)
    image.draw(in: NSRect(x: 0, y: -rect.height, width: rect.width, height: rect.height))
    cgContext.restoreGState()
}

/// Character-count based word wrap, matching `textwrap.wrap(text, width:)`
/// from the Python scripts (not pixel-measured, just word-boundary
/// wrapping). Splits on *any* whitespace (not just plain spaces) and
/// collapses runs of it, matching Python's default `replace_whitespace`
/// behavior — needed because e.g. the real `fortune` command frequently
/// returns quotes with embedded newlines/tabs, which previously broke the
/// line-height math and caused overlapping text.
public func wrapText(_ text: String, maxCharsPerLine: Int, maxLines: Int? = nil) -> [String] {
    var lines: [String] = []
    var currentLine = ""
    for word in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = currentLine.isEmpty ? String(word) : currentLine + " " + word
        if candidate.count > maxCharsPerLine, !currentLine.isEmpty {
            lines.append(currentLine)
            currentLine = String(word)
        } else {
            currentLine = candidate
        }
    }
    if !currentLine.isEmpty { lines.append(currentLine) }
    if let maxLines {
        return Array(lines.prefix(maxLines))
    }
    return lines
}

/// `wrapText` with `maxLines`, but without the abrupt stop: when the text is
/// too long it ends on the last whole sentence that fits (as long as that
/// keeps a reasonable amount of the text), otherwise on a whole word followed
/// by "…" — rather than cutting off mid-sentence.
public func wrapTextEndingCleanly(_ text: String, maxCharsPerLine: Int, maxLines: Int) -> [String] {
    let all = wrapText(text, maxCharsPerLine: maxCharsPerLine)
    guard all.count > maxLines else { return all }

    let kept = all.prefix(maxLines).joined(separator: " ")
    if let sentenceEnd = lastSentenceEnd(in: kept), kept.distance(from: kept.startIndex, to: sentenceEnd) * 10 >= kept.count * 4 {
        return wrapText(String(kept[..<sentenceEnd]), maxCharsPerLine: maxCharsPerLine)
    }

    var words = kept.split(separator: " ").map(String.init)
    while !words.isEmpty {
        var candidate = words.joined(separator: " ")
        while let last = candidate.last, ",;:-–—(".contains(last) { candidate.removeLast() }
        let lines = wrapText(candidate + "…", maxCharsPerLine: maxCharsPerLine)
        if lines.count <= maxLines { return lines }
        words.removeLast()
    }
    return Array(all.prefix(maxLines))
}

/// The index just past the last sentence-ending punctuation in `text`
/// (a ".", "!" or "?" followed by whitespace or the end of the string).
private func lastSentenceEnd(in text: String) -> String.Index? {
    guard let regex = try? NSRegularExpression(pattern: "[.!?][\"'”’)]?(?=\\s|$)") else { return nil }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last, let range = Range(last.range, in: text) else { return nil }
    return range.upperBound
}

/// Word-wraps `text` to fit within `maxWidth` points at `font`, measuring
/// each candidate line's actual rendered width rather than approximating by
/// character count — needed when the font size itself varies (see
/// `fittingFontSize` below), since a fixed character count doesn't
/// correspond to a fixed pixel width across different sizes.
public func wrapTextToWidth(_ text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    var lines: [String] = []
    var currentLine = ""
    for word in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = currentLine.isEmpty ? String(word) : currentLine + " " + word
        let width = (candidate as NSString).size(withAttributes: attrs).width
        if width > maxWidth, !currentLine.isEmpty {
            lines.append(currentLine)
            currentLine = String(word)
        } else {
            currentLine = candidate
        }
    }
    if !currentLine.isEmpty { lines.append(currentLine) }
    return lines
}

/// Picks the largest font size in `range` (falling back to the smallest if
/// even that overflows) such that `text`, wrapped to `maxWidth`, fits
/// within `maxHeight` — a simple "shrink/grow to fit" so a short quote
/// renders big and fills the frame, while a long one still fits without
/// overflowing, instead of one fixed size regardless of content length.
/// Decodes an image file via ImageIO rather than `NSImage(data:)` +
/// `tiffRepresentation` — the latter can wash out colors on wide-gamut/HDR
/// sources like iPhone HEIC photos, since it doesn't reliably color-manage
/// the embedded profile. This also bakes in any EXIF orientation
/// (`kCGImageSourceCreateThumbnailWithTransform`) so the pixels come out
/// upright regardless of source format.
public func loadUprightCGImage(at url: URL, maxPixelSize: Int = 2400) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return uprightThumbnail(from: source, maxPixelSize: maxPixelSize)
}

/// Same as `loadUprightCGImage(at:maxPixelSize:)` but for image bytes already
/// in memory (e.g. fetched over HTTP) rather than a file on disk.
public func loadUprightCGImage(data: Data, maxPixelSize: Int = 2400) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return uprightThumbnail(from: source, maxPixelSize: maxPixelSize)
}

private func uprightThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Fits `cgImage` into a `width`x`height` canvas preserving its aspect
/// ratio, letterboxing with `background` — so the frame displays the whole
/// photo instead of cropping it to fill the screen when the photo's aspect
/// ratio doesn't match the frame's.
public func renderLetterboxed(cgImage: CGImage, width: Int, height: Int, background: NSColor) -> NSImage? {
    ImageCanvas.render(width: width, height: height) {
        background.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let canvasAspect = CGFloat(width) / CGFloat(height)
        let fitWidth: CGFloat
        let fitHeight: CGFloat
        if imageAspect > canvasAspect {
            fitWidth = CGFloat(width)
            fitHeight = fitWidth / imageAspect
        } else {
            fitHeight = CGFloat(height)
            fitWidth = fitHeight * imageAspect
        }
        let rect = NSRect(
            x: (CGFloat(width) - fitWidth) / 2,
            y: (CGFloat(height) - fitHeight) / 2,
            width: fitWidth,
            height: fitHeight
        )
        drawImage(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), in: rect)
    }
}

/// Fits `cgImage` into a `width`x`height` canvas by scaling to *cover* the
/// canvas and cropping the overflow, centered — the opposite tradeoff to
/// `renderLetterboxed`: no padding bars, but part of the photo is cut off.
/// Meant for a landscape photo on a portrait frame, where fitting the whole
/// image renders it small in the middle of two large background bars.
public func renderFilled(cgImage: CGImage, width: Int, height: Int) -> NSImage? {
    ImageCanvas.render(width: width, height: height) {
        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let canvasAspect = CGFloat(width) / CGFloat(height)
        let fitWidth: CGFloat
        let fitHeight: CGFloat
        if imageAspect > canvasAspect {
            // Wider than the canvas: match height, overflow left/right.
            fitHeight = CGFloat(height)
            fitWidth = fitHeight * imageAspect
        } else {
            // Taller than the canvas: match width, overflow top/bottom.
            fitWidth = CGFloat(width)
            fitHeight = fitWidth / imageAspect
        }
        let rect = NSRect(
            x: (CGFloat(width) - fitWidth) / 2,
            y: (CGFloat(height) - fitHeight) / 2,
            width: fitWidth,
            height: fitHeight
        )
        // CGContext clips drawing to its own bounds automatically, so the
        // overflow left/right or top/bottom is simply cut off here — no
        // explicit clip path needed.
        drawImage(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), in: rect)
    }
}

/// Renders the part of `cgImage` that `crop` selects so it exactly fills a
/// `width`x`height` canvas. The selected rectangle has the canvas's own
/// aspect ratio, so this scales it to fit with nothing left over.
public func renderCropped(cgImage: CGImage, crop: CropRegion, width: Int, height: Int) -> NSImage? {
    let imageWidth = Double(cgImage.width)
    let imageHeight = Double(cgImage.height)
    let region = crop.pixelRect(imageWidth: imageWidth, imageHeight: imageHeight, canvasAspect: Double(width) / Double(height))
    let scale = CGFloat(width) / region.width
    let rect = NSRect(
        x: -region.minX * scale,
        y: -region.minY * scale,
        width: imageWidth * scale,
        height: imageHeight * scale
    )
    return ImageCanvas.render(width: width, height: height) {
        drawImage(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), in: rect)
    }
}

public func fittingFontSize(
    for text: String,
    fontName: String,
    range: ClosedRange<CGFloat>,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    lineHeightMultiplier: CGFloat = 1.3,
    step: CGFloat = 2
) -> (font: NSFont, lines: [String], lineHeight: CGFloat) {
    func attempt(_ size: CGFloat) -> (font: NSFont, lines: [String], lineHeight: CGFloat) {
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let lines = wrapTextToWidth(text, font: font, maxWidth: maxWidth)
        return (font, lines, size * lineHeightMultiplier)
    }

    var size = range.upperBound
    while size > range.lowerBound {
        let candidate = attempt(size)
        if CGFloat(candidate.lines.count) * candidate.lineHeight <= maxHeight {
            return candidate
        }
        size -= step
    }
    return attempt(range.lowerBound)
}
