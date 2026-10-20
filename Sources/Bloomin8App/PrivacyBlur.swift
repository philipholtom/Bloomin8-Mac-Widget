import Bloomin8Core
import CoreImage
import SwiftUI

/// The one on/off switch for hiding previews of locked content (pixelated or
/// blurred), shared by every view that draws a preview (grids, inspector,
/// pickers, crop window) so flipping it anywhere flips it everywhere. Off by
/// default; the last choices are remembered across launches.
@MainActor
final class PrivacyBlur: ObservableObject {
    static let shared = PrivacyBlur()

    enum Style: String, CaseIterable, Identifiable {
        case pixelate
        case blur

        var id: String { rawValue }
        var label: String { self == .pixelate ? "Pixelate" : "Blur" }
    }

    private static let enabledKey = "blurLockedPreviews"
    private static let styleKey = "blurLockedStyle"
    private static let radiusKey = "blurLockedRadius"
    private static let pixelKey = "blurLockedPixelFraction"

    /// Quick choices for the right-click menus. `radius` is the blur radius
    /// for a 300-point-tall preview (smaller previews get proportionally
    /// less); `pixelFraction` is the pixel block size as a fraction of the
    /// picture's shorter side.
    static let presets: [(name: String, radius: Double, pixelFraction: Double)] = [
        ("Light", 6, 0.04), ("Medium", 12, 0.07), ("Strong", 24, 0.12)
    ]
    static let radiusRange: ClosedRange<Double> = 3...40
    static let pixelRange: ClosedRange<Double> = 0.02...0.2
    static let defaultRadius = 12.0
    static let defaultPixelFraction = 0.07

    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @Published var style: Style {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }
    @Published var radius: Double {
        didSet { defaults.set(radius, forKey: Self.radiusKey) }
    }
    @Published var pixelFraction: Double {
        didSet { defaults.set(pixelFraction, forKey: Self.pixelKey) }
    }

    private init() {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.style = (defaults.string(forKey: Self.styleKey)).flatMap(Style.init(rawValue:)) ?? .pixelate
        let savedRadius = defaults.object(forKey: Self.radiusKey) as? Double
        self.radius = savedRadius.map { min(max($0, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) } ?? Self.defaultRadius
        let savedPixel = defaults.object(forKey: Self.pixelKey) as? Double
        self.pixelFraction = savedPixel.map { min(max($0, Self.pixelRange.lowerBound), Self.pixelRange.upperBound) } ?? Self.defaultPixelFraction
    }

    /// Whether content with these properties counts as "locked": a photo in a
    /// gallery that's been put in the locked list (even after unlocking it),
    /// or a local file when Local Folder / Favorites / Browse Files are
    /// behind the password.
    static func appliesTo(settings: AppSettings, gallery: String?, isLocalFile: Bool) -> Bool {
        if let gallery, settings.tabs.contains(where: { $0.isLocked && $0.galleryNames.contains(gallery) }) {
            return true
        }
        return isLocalFile && settings.localFolderLocked
    }

    // MARK: - Pixelation

    private static let ciContext = CIContext()

    private final class CacheEntry {
        weak var source: NSImage?
        let fraction: Double
        let result: NSImage
        init(source: NSImage, fraction: Double, result: NSImage) {
            self.source = source
            self.fraction = fraction
            self.result = result
        }
    }

    private static let cache: NSCache<NSNumber, CacheEntry> = {
        let cache = NSCache<NSNumber, CacheEntry>()
        cache.countLimit = 400
        return cache
    }()

    /// `image` with its detail replaced by square blocks whose side is
    /// `fraction` of the shorter side of the picture. Cached per image and
    /// block size, so scrolling a big grid doesn't redo the work.
    static func pixelated(_ image: NSImage, fraction: Double) -> NSImage {
        let key = NSNumber(value: ObjectIdentifier(image).hashValue)
        if let hit = cache.object(forKey: key), hit.source === image, hit.fraction == fraction {
            return hit.result
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate")
        else { return image }
        let input = CIImage(cgImage: cgImage)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(Double(min(cgImage.width, cgImage.height)) * fraction, 2), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let rendered = ciContext.createCGImage(output, from: input.extent)
        else { return image }
        let result = NSImage(cgImage: rendered, size: image.size)
        cache.setObject(CacheEntry(source: image, fraction: fraction, result: result), forKey: key)
        return result
    }
}

/// Draws a photo, pixelated if the switch is on, the style is Pixelate and
/// the photo is locked content. (For the Blur style it draws the photo as
/// normal and `privacyBlur`, applied on the outside, does the blurring —
/// blur works on any view, pixelation has to work on the image itself.)
struct PrivacyImage: View {
    @ObservedObject private var privacy = PrivacyBlur.shared
    let image: NSImage
    let settings: AppSettings?
    let gallery: String?
    let isLocalFile: Bool

    init(_ image: NSImage, settings: AppSettings?, gallery: String? = nil, isLocalFile: Bool = false) {
        self.image = image
        self.settings = settings
        self.gallery = gallery
        self.isLocalFile = isLocalFile
    }

    /// Lets existing `Image(nsImage:).resizable()` call sites switch over
    /// with only the first word changed; the image is always resizable.
    func resizable() -> PrivacyImage { self }

    var body: some View {
        if let settings, privacy.enabled, privacy.style == .pixelate,
           PrivacyBlur.appliesTo(settings: settings, gallery: gallery, isLocalFile: isLocalFile) {
            Image(nsImage: PrivacyBlur.pixelated(image, fraction: privacy.pixelFraction))
                .resizable()
        } else {
            Image(nsImage: image)
                .resizable()
        }
    }
}

/// Blurs its content while the switch is on, the style is Blur, and the
/// content is locked.
struct PrivacyBlurModifier: ViewModifier {
    @ObservedObject private var privacy = PrivacyBlur.shared
    let settings: AppSettings
    let gallery: String?
    let isLocalFile: Bool
    /// The shorter side of what's being blurred, so the blur scales with it.
    @State private var side: CGFloat = 300

    func body(content: Content) -> some View {
        let active = privacy.enabled && privacy.style == .blur
            && PrivacyBlur.appliesTo(settings: settings, gallery: gallery, isLocalFile: isLocalFile)
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { side = min(geo.size.width, geo.size.height) }
                        .onChange(of: geo.size) { side = min($0.width, $0.height) }
                }
            )
            .blur(radius: active ? privacy.radius * max(side, 40) / 300 : 0)
            .clipped()
            .animation(.easeInOut(duration: 0.15), value: active)
    }
}

extension View {
    /// Blurs this preview while hiding is on and the style is Blur, if the
    /// photo comes from a locked gallery (`gallery`) or is a local file
    /// (`isLocalFile`) behind the Local Folder lock. (Pixelation is handled by
    /// `PrivacyImage`.)
    func privacyBlur(settings: AppSettings, gallery: String? = nil, isLocalFile: Bool = false) -> some View {
        modifier(PrivacyBlurModifier(settings: settings, gallery: gallery, isLocalFile: isLocalFile))
    }

    /// `privacyBlur` for a local file, when settings are available.
    @ViewBuilder
    func privacyBlurIfLocal(settings: AppSettings?) -> some View {
        if let settings {
            privacyBlur(settings: settings, isLocalFile: true)
        } else {
            self
        }
    }
}

/// A small eye button that flips hiding on and off, for sitting on top of a
/// preview. Only shows when the preview is of locked content, so ordinary
/// photos don't get a control that does nothing for them.
struct PrivacyBlurButton: View {
    @ObservedObject private var privacy = PrivacyBlur.shared
    let settings: AppSettings
    var gallery: String?
    var isLocalFile = false

    var body: some View {
        if PrivacyBlur.appliesTo(settings: settings, gallery: gallery, isLocalFile: isLocalFile) {
            Button {
                privacy.enabled.toggle()
            } label: {
                Image(systemName: privacy.enabled ? "eye.slash" : "eye")
                    .font(.system(size: 13, weight: .medium))
                    .padding(7)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(privacy.enabled ? "Hidden — click to show locked previews (right-click for style)" : "Click to hide locked previews (right-click for style)")
            .contextMenu { PrivacyBlurStrengthMenu() }
        }
    }
}

/// Style and Light / Medium / Strong quick choices, for a right-click menu.
struct PrivacyBlurStrengthMenu: View {
    @ObservedObject private var privacy = PrivacyBlur.shared

    var body: some View {
        Picker("Style", selection: $privacy.style) {
            ForEach(PrivacyBlur.Style.allCases) { Text($0.label).tag($0) }
        }
        Divider()
        ForEach(PrivacyBlur.presets, id: \.name) { preset in
            Button {
                privacy.radius = preset.radius
                privacy.pixelFraction = preset.pixelFraction
                privacy.enabled = true
            } label: {
                if isCurrent(preset) {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
        }
    }

    private func isCurrent(_ preset: (name: String, radius: Double, pixelFraction: Double)) -> Bool {
        privacy.style == .pixelate
            ? abs(privacy.pixelFraction - preset.pixelFraction) < 0.005
            : abs(privacy.radius - preset.radius) < 0.5
    }
}

/// A stand-in picture drawn at the current style and strength, so the
/// settings show what they do without needing a real locked photo.
struct PrivacyBlurSample: View {
    @ObservedObject private var privacy = PrivacyBlur.shared
    @State private var sample: NSImage?

    private var shapes: some View {
        ZStack {
            Rectangle().fill(Color.orange.opacity(0.75))
            Circle().fill(Color.white).frame(width: 46, height: 46).offset(x: -34, y: -8)
            Rectangle().fill(Color.blue.opacity(0.8)).frame(width: 52, height: 30).offset(x: 30, y: 16)
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(Color.black.opacity(0.7)).frame(width: 90, height: 3)
                }
            }
            .offset(y: -30)
        }
        .frame(width: 160, height: 100)
    }

    var body: some View {
        Group {
            if privacy.style == .pixelate, let sample {
                Image(nsImage: PrivacyBlur.pixelated(sample, fraction: privacy.pixelFraction))
                    .resizable()
                    .frame(width: 160, height: 100)
            } else {
                shapes.blur(radius: privacy.radius * 100 / 300)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            let renderer = ImageRenderer(content: shapes)
            renderer.scale = 2
            sample = renderer.nsImage
        }
    }
}
