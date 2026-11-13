import AppKit

/// A mat or border drawn around each photo before it's sent. Off by default.
public struct FrameStyle: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case none = "None"
        case even = "Even mat"
        case gallery = "Gallery mat"
        case polaroid = "Polaroid"
        public var id: String { rawValue }

        /// A line about what it looks like, for the settings screen.
        public var summary: String {
            switch self {
            case .none: return "The photo fills the frame."
            case .even: return "The same border on every side."
            case .gallery: return "A little deeper at the bottom, like a framed print."
            case .polaroid: return "Thin sides and top, a deep bottom edge."
            }
        }
    }

    public enum Colour: String, Codable, CaseIterable, Identifiable {
        case white = "White"
        case black = "Black"
        public var id: String { rawValue }
        var nsColor: NSColor { self == .white ? .white : .black }
    }

    public var kind: Kind = .none
    /// The border's width as a percentage of the frame's shorter side (3–16).
    public var widthPercent: Double = 8
    public var colour: Colour = .white
    /// A thin line around the photo, like the cut edge of a mount.
    public var keyline = false
    /// Write the photo's title and date in the deep bottom edge of a Gallery
    /// mat or Polaroid, when the photo has them.
    public var caption = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case kind, widthPercent, colour, keyline, caption }

    /// Missing keys fall back to their defaults, so a style saved by an older
    /// version (before captions existed) still loads instead of resetting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
        widthPercent = try c.decodeIfPresent(Double.self, forKey: .widthPercent) ?? 8
        colour = try c.decodeIfPresent(Colour.self, forKey: .colour) ?? .white
        keyline = try c.decodeIfPresent(Bool.self, forKey: .keyline) ?? false
        caption = try c.decodeIfPresent(Bool.self, forKey: .caption) ?? true
    }

    /// Whether this style has a bottom edge deep enough for a caption.
    public var showsCaption: Bool { caption && (kind == .polaroid || kind == .gallery) }

    public var isNone: Bool { kind == .none }

    /// Empty when off, so photos sent without a mat keep exactly the
    /// fingerprint (and on-frame filename) they always had.
    public var fingerprint: String {
        isNone ? "" : "|mat:\(kind.rawValue),\(widthPercent),\(colour.rawValue),\(keyline),\(showsCaption)"
    }

    private static let defaultsKey = "frameStyle"

    /// Read from the shared defaults each time, like `EInkTuning.stored()`:
    /// both products and the rendering threads always see the latest.
    public static func stored() -> FrameStyle {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(FrameStyle.self, from: data) else { return FrameStyle() }
        return decoded
    }

    public static func store(_ style: FrameStyle, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The border widths (left, top, right, bottom) for a `width`x`height` frame.
    func insets(width: Int, height: Int) -> (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        let base = CGFloat(min(width, height)) * CGFloat(max(3, min(16, widthPercent))) / 100
        switch kind {
        case .none: return (0, 0, 0, 0)
        case .even: return (base, base, base, base)
        case .gallery: return (base, base, base, base * 1.4)
        case .polaroid: return (base * 0.7, base * 0.7, base * 0.7, base * 2.6)
        }
    }
}

/// The words under a photo in a Gallery mat or Polaroid: its title, and the
/// date it was taken, from the photo's own metadata. Photos with neither get
/// no caption. (The place isn't included: looking it up needs a network
/// request, which this drawing step doesn't make.)
public struct FrameCaption: Equatable, Sendable {
    public var title: String
    public var date: String

    public init(title: String, date: String) {
        self.title = title
        self.date = date
    }

    public var isEmpty: Bool { title.isEmpty && date.isEmpty }

    /// Nil straight away when the current style doesn't show captions, so
    /// photos aren't opened for metadata that wouldn't be used.
    public static func read(url: URL) -> FrameCaption? {
        guard FrameStyle.stored().showsCaption else { return nil }
        return PhotoMetadata.read(from: url).flatMap(from)
    }

    public static func read(data: Data) -> FrameCaption? {
        guard FrameStyle.stored().showsCaption else { return nil }
        return PhotoMetadata.read(from: data).flatMap(from)
    }

    public static func from(_ meta: PhotoMetadata) -> FrameCaption? {
        let title = MuseumCardBuilder.cleanTitle(meta.title)
        var date = ""
        if let taken = meta.dateTaken {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
            date = formatter.string(from: taken)
        }
        let caption = FrameCaption(title: title, date: date)
        return caption.isEmpty ? nil : caption
    }
}

public enum FrameStyler {
    /// `photo` set in a mat on a `width`x`height` canvas. With `fill` the
    /// photo is cropped to fill the space inside the mat (a landscape photo
    /// on a portrait frame, when that setting is on); otherwise the whole
    /// photo is shown, centred in that space.
    public static func compose(_ photo: CGImage, style: FrameStyle, width: Int, height: Int, fill: Bool, caption: FrameCaption? = nil) -> NSImage? {
        let inset = style.insets(width: width, height: height)
        let inner = CGRect(x: inset.left, y: inset.top,
                           width: CGFloat(width) - inset.left - inset.right,
                           height: CGFloat(height) - inset.top - inset.bottom)
        guard inner.width > 10, inner.height > 10 else { return nil }

        // Where the photo sits inside the mat.
        let target: CGRect
        if fill {
            target = inner
        } else {
            let scale = min(inner.width / CGFloat(photo.width), inner.height / CGFloat(photo.height))
            let w = (CGFloat(photo.width) * scale).rounded(), h = (CGFloat(photo.height) * scale).rounded()
            target = CGRect(x: inner.minX + ((inner.width - w) / 2).rounded(), y: inner.minY + ((inner.height - h) / 2).rounded(), width: w, height: h)
        }

        // The photo, scaled (and for "fill" cropped from the middle) to `target`.
        let photoImage: NSImage?
        if fill {
            photoImage = renderFilled(cgImage: photo, width: Int(target.width), height: Int(target.height))
        } else {
            photoImage = NSImage(cgImage: photo, size: NSSize(width: photo.width, height: photo.height))
        }
        guard let photoImage else { return nil }

        return ImageCanvas.render(width: width, height: height) {
            style.colour.nsColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            if let context = NSGraphicsContext.current {
                let previous = context.imageInterpolation
                context.imageInterpolation = .high
                drawImage(photoImage, in: NSRect(x: target.minX, y: target.minY, width: target.width, height: target.height))
                context.imageInterpolation = previous
            }
            if style.keyline {
                // A hairline just outside the photo, in whichever of black/white shows against the mat.
                (style.colour == .white ? NSColor.black : NSColor.white).setStroke()
                let path = NSBezierPath(rect: target.insetBy(dx: -2, dy: -2))
                path.lineWidth = 2
                path.stroke()
            }
            if style.showsCaption, let caption, !caption.isEmpty {
                let area = CGRect(x: inset.left, y: CGFloat(height) - inset.bottom, width: CGFloat(width) - inset.left - inset.right, height: inset.bottom)
                drawCaption(caption, in: area, colour: style.colour == .white ? .black : .white)
            }
        }
    }

    /// The title in a handwritten face (it suits a Polaroid, and its strokes are
    /// thick enough for e-ink), the date smaller beneath, both centred in the
    /// bottom edge and shrunk to fit its width.
    private static func drawCaption(_ caption: FrameCaption, in area: CGRect, colour: NSColor) {
        func fitted(_ names: [String], size: CGFloat, maxWidth: CGFloat, text: String) -> NSFont {
            var current = size
            while true {
                let font = names.lazy.compactMap { NSFont(name: $0, size: current) }.first ?? NSFont.systemFont(ofSize: current)
                if current <= 14 || (text as NSString).size(withAttributes: [.font: font]).width <= maxWidth { return font }
                current -= 2
            }
        }
        let maxWidth = area.width * 0.94
        let hasTitle = !caption.title.isEmpty, hasDate = !caption.date.isEmpty
        let titleSize = min(area.height * (hasDate ? 0.30 : 0.36), 90)
        let titleFont = fitted(["BradleyHandITCTT-Bold", "Noteworthy-Bold", "Helvetica-Bold"], size: titleSize, maxWidth: maxWidth, text: caption.title)
        let dateFont = fitted(["BradleyHandITCTT-Bold", "Noteworthy-Light", "Helvetica"], size: titleSize * 0.62, maxWidth: maxWidth, text: caption.date)
        let titleHeight = hasTitle ? titleFont.pointSize * 1.25 : 0
        let dateHeight = hasDate ? dateFont.pointSize * 1.25 : 0
        var y = area.minY + max(0, (area.height - titleHeight - dateHeight) / 2)
        if hasTitle { drawLine(caption.title, font: titleFont, colour: colour, centerX: area.midX, top: y); y += titleHeight }
        if hasDate { drawLine(caption.date, font: dateFont, colour: colour, centerX: area.midX, top: y) }
    }

    private static func drawLine(_ text: String, font: NSFont, colour: NSColor, centerX: CGFloat, top: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let string = text as NSString
        let size = string.size(withAttributes: attrs)
        context.saveGState()
        context.translateBy(x: centerX - size.width / 2, y: top + size.height)
        context.scaleBy(x: 1, y: -1)
        string.draw(at: .zero, withAttributes: attrs)
        context.restoreGState()
    }
}
