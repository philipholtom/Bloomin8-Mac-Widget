import Bloomin8Core
import AppKit
import SwiftUI

/// Settings → Photos → "Tune for e-ink": a preset and sliders for how photos
/// are adjusted before sending, with a side-by-side preview of the result and
/// of roughly what the frame's six-colour conversion makes of it.
struct EInkTuningView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var sourceImage: CGImage?
    @State private var sourceName = "the photo on the frame"
    @State private var tunedImage: NSImage?
    @State private var simulatedImage: NSImage?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjusts photos before they're sent, so the frame's six-colour conversion has more to work with. Applies to photos from your Mac and Photos library, not to generated pictures.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Preset", selection: presetBinding) {
                ForEach(EInkTuning.Preset.allCases) { Text($0.rawValue).tag(Optional($0)) }
                if settings.einkTuning.matchingPreset == nil { Text("Custom").tag(Optional<EInkTuning.Preset>.none) }
            }
            .frame(maxWidth: 320)

            slider("Brightness", value: $settings.einkTuning.brightness, range: -0.3...0.3, neutral: 0, format: "%+.2f")
            slider("Contrast", value: $settings.einkTuning.contrast, range: 0.7...1.6, neutral: 1, format: "%.2f")
            slider("Midtones (gamma)", value: $settings.einkTuning.gamma, range: 0.6...1.6, neutral: 1, format: "%.2f")
            slider("Colour saturation", value: $settings.einkTuning.saturation, range: 0.5...1.8, neutral: 1, format: "%.2f")
            slider("Sharpening", value: $settings.einkTuning.sharpness, range: 0...1, neutral: 0, format: "%.2f")

            HStack {
                Button("Reset to none") { settings.einkTuning = EInkTuning() }
                    .disabled(settings.einkTuning.isNeutral)
                Button("Preview another photo…") { chooseSource() }
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }

            preview
            Text("Preview of \(sourceName). The right-hand picture is only a guide: the frame's own conversion and the panel's real colours differ a little. Settings apply to photos sent from now on; ones already on the frame stay as they are.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .task { loadFromFrame() }
        .onChange(of: controller.previewImage) { _ in if sourceName == "the photo on the frame" { loadFromFrame() } }
        .task(id: settings.einkTuning) {
            // Wait a beat so dragging a slider doesn't render every step.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
    }

    // MARK: - Pieces

    private var presetBinding: Binding<EInkTuning.Preset?> {
        Binding(get: { settings.einkTuning.matchingPreset },
                set: { if let preset = $0 { settings.einkTuning = preset.tuning } })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double, format: String) -> some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 12) {
            tile("Original", image: sourceImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            tile("Tuned", image: tunedImage)
            tile("On the frame (approx.)", image: simulatedImage)
        }
    }

    private func tile(_ title: String, image: NSImage?) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(height: 200)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Work

    private func loadFromFrame() {
        guard let image = controller.previewImage,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        sourceImage = Self.shrunk(cg)
        sourceName = "the photo on the frame"
        Task { await rebuildPreview() }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let cg = loadUprightCGImage(at: url, maxPixelSize: 1700) else { return }
        sourceImage = Self.shrunk(cg)
        sourceName = url.lastPathComponent
        Task { await rebuildPreview() }
    }

    private static func shrunk(_ image: CGImage, maxHeight: Int = 1600) -> CGImage {
        guard image.height > maxHeight else { return image }
        let scale = Double(maxHeight) / Double(image.height)
        let w = Int(Double(image.width) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: maxHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: maxHeight))
        return ctx.makeImage() ?? image
    }

    private func rebuildPreview() async {
        guard let source = sourceImage else { return }
        let tuning = settings.einkTuning
        working = true
        let result: (NSImage?, NSImage?) = await Task.detached(priority: .userInitiated) {
            let tuned = EInkTuner.apply(tuning, to: source)
            let simulated = EInkSimulator.simulate(tuned)
            return (
                NSImage(cgImage: tuned, size: NSSize(width: tuned.width, height: tuned.height)),
                simulated.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            )
        }.value
        tunedImage = result.0
        simulatedImage = result.1
        working = false
    }
}
