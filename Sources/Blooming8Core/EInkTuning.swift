import AppKit
import CoreImage

/// How photos are adjusted before they're sent, so the frame's own
/// six-colour conversion (black, white, red, green, blue, yellow) starts from
/// something that survives it. The defaults change nothing.
public struct EInkTuning: Codable, Equatable {
    /// -0.3 ... 0.3; 0 leaves it alone.
    public var brightness: Double = 0
    /// 0.7 ... 1.6; 1 leaves it alone.
    public var contrast: Double = 1
    /// 0.6 ... 1.6; below 1 lightens the midtones (a shadow-friendly curve), 1 leaves it alone.
    public var gamma: Double = 1
    /// 0.5 ... 1.8; 1 leaves it alone.
    public var saturation: Double = 1
    /// 0 ... 1; 0 leaves it alone.
    public var sharpness: Double = 0

    public init() {}

    public var isNeutral: Bool { self == EInkTuning() }

    public enum Preset: String, CaseIterable, Identifiable {
        case none = "None"
        case photo = "Photo"
        case art = "Art / poster"
        case highContrast = "High contrast"
        public var id: String { rawValue }

        /// Starting points to adjust from, not measured values.
        public var tuning: EInkTuning {
            var t = EInkTuning()
            switch self {
            case .none: break
            case .photo:
                t.brightness = 0.02; t.contrast = 1.12; t.gamma = 0.92; t.saturation = 1.2; t.sharpness = 0.4
            case .art:
                t.contrast = 1.2; t.saturation = 1.35; t.sharpness = 0.3
            case .highContrast:
                t.contrast = 1.35; t.gamma = 0.9; t.saturation = 1.1; t.sharpness = 0.6
            }
            return t
        }
    }

    /// The preset these values match exactly, if any.
    public var matchingPreset: Preset? { Preset.allCases.first { $0.tuning == self } }

    // MARK: - Where it's stored

    private static let defaultsKey = "einkTuning"

    /// Read from the shared defaults each time rather than from a
    /// process-wide copy, so the widget and the app (and the threads that
    /// render photos) always see the latest, with no stale in-memory value.
    public static func stored() -> EInkTuning {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(EInkTuning.self, from: data) else { return EInkTuning() }
        return decoded
    }

    public static func store(_ tuning: EInkTuning, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(tuning) { defaults.set(data, forKey: defaultsKey) }
    }

    /// Empty when neutral — so photos sent without tuning keep exactly the
    /// fingerprint (and on-frame filename) they always had.
    public var fingerprint: String {
        isNeutral ? "" : "|tune:\(brightness),\(contrast),\(gamma),\(saturation),\(sharpness)"
    }
}

public enum EInkTuner {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// `image` with `tuning` applied; the original when tuning is neutral.
    public static func apply(_ tuning: EInkTuning, to image: CGImage) -> CGImage {
        guard !tuning.isNeutral else { return image }
        var ci = CIImage(cgImage: image)
        ci = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: tuning.brightness,
            kCIInputContrastKey: tuning.contrast,
            kCIInputSaturationKey: tuning.saturation
        ])
        if tuning.gamma != 1 {
            ci = ci.applyingFilter("CIGammaAdjust", parameters: ["inputPower": tuning.gamma])
        }
        if tuning.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: tuning.sharpness * 1.2])
        }
        return context.createCGImage(ci, from: CIImage(cgImage: image).extent) ?? image
    }

    public static func apply(_ tuning: EInkTuning, to image: NSImage) -> NSImage {
        guard !tuning.isNeutral, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let tuned = apply(tuning, to: cg)
        return NSImage(cgImage: tuned, size: NSSize(width: tuned.width, height: tuned.height))
    }
}

/// An approximation of how a photo looks after the frame reduces it to its six
/// colours, for judging tuning without sending anything. The frame's own
/// conversion and the panel's real colours differ somewhat; this is a guide.
public enum EInkSimulator {
    /// Rough on-panel colours (the pigments are muted compared with a screen).
    private static let palette: [(r: Double, g: Double, b: Double)] = [
        (25, 25, 28),     // black
        (196, 197, 190),  // white
        (150, 38, 32),    // red
        (48, 100, 62),    // green
        (32, 62, 135),    // blue
        (205, 175, 32)    // yellow
    ]

    /// What the frame would show, at roughly the size it's shown on screen.
    /// The dither is done at the frame's real resolution (`ditherHeight`
    /// pixels tall — 1600 on this panel) and only then shrunk with smoothing
    /// to `outputHeight`, the way your eye blends the dots on the real panel.
    /// Dithering a small copy instead makes the dots several times too big.
    public static func simulate(_ image: CGImage, ditherHeight: Int = 1600, outputHeight: Int = 520) -> CGImage? {
        guard let dithered = ditherToPalette(image, height: ditherHeight) else { return nil }
        guard dithered.height > outputHeight else { return dithered }
        let w = max(1, dithered.width * outputHeight / dithered.height)
        guard let ctx = CGContext(data: nil, width: w, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return dithered }
        ctx.interpolationQuality = .high
        ctx.draw(dithered, in: CGRect(x: 0, y: 0, width: w, height: outputHeight))
        return ctx.makeImage()
    }

    /// Floyd–Steinberg dither of `image` (scaled to `height` tall) to the six colours.
    static func ditherToPalette(_ image: CGImage, height maxHeight: Int) -> CGImage? {
        let scale = Double(maxHeight) / Double(image.height)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Work in floating point so the carried error doesn't clip early.
        var buf = [Double](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            buf[i * 3] = Double(pixels[i * 4]); buf[i * 3 + 1] = Double(pixels[i * 4 + 1]); buf[i * 3 + 2] = Double(pixels[i * 4 + 2])
        }
        func spread(_ x: Int, _ y: Int, _ er: Double, _ eg: Double, _ eb: Double, _ f: Double) {
            guard x >= 0, x < w, y < h else { return }
            let i = (y * w + x) * 3
            buf[i] += er * f; buf[i + 1] += eg * f; buf[i + 2] += eb * f
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let r = min(255, max(0, buf[i])), g = min(255, max(0, buf[i + 1])), b = min(255, max(0, buf[i + 2]))
                var best = 0, bestDist = Double.infinity
                for (k, p) in palette.enumerated() {
                    // Weighted so green differences count most, as the eye does.
                    let d = 0.30 * (r - p.r) * (r - p.r) + 0.59 * (g - p.g) * (g - p.g) + 0.11 * (b - p.b) * (b - p.b)
                    if d < bestDist { bestDist = d; best = k }
                }
                let p = palette[best]
                let er = r - p.r, eg = g - p.g, eb = b - p.b
                spread(x + 1, y, er, eg, eb, 7 / 16)
                spread(x - 1, y + 1, er, eg, eb, 3 / 16)
                spread(x, y + 1, er, eg, eb, 5 / 16)
                spread(x + 1, y + 1, er, eg, eb, 1 / 16)
                pixels[(y * w + x) * 4] = UInt8(p.r); pixels[(y * w + x) * 4 + 1] = UInt8(p.g)
                pixels[(y * w + x) * 4 + 2] = UInt8(p.b); pixels[(y * w + x) * 4 + 3] = 255
            }
        }
        return ctx.makeImage()
    }
}
