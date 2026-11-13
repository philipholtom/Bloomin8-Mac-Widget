import Bloomin8Core
import AppKit
import SwiftUI

/// Settings → Photos → "Mats & borders": a border drawn around each photo
/// before it's sent, with a preview of the result on a chosen photo.
struct FrameStyleView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: PhotoController

    @State private var sourceImage: CGImage?
    @State private var sourceName = "the photo on the frame"
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sets each photo in a mat or border before it's sent, in place of the black bars or edge-to-edge fill. Applies to photos from your Mac and Photos library, not to generated pictures.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Style", selection: $settings.frameStyle.kind) {
                ForEach(FrameStyle.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 320)
            Text(settings.frameStyle.kind.summary).font(.caption).foregroundStyle(.secondary)

            if !settings.frameStyle.isNone {
                HStack {
                    Text("Width").frame(width: 60, alignment: .leading)
                    Slider(value: $settings.frameStyle.widthPercent, in: 3...16)
                    Text("\(Int(settings.frameStyle.widthPercent))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Picker("Colour", selection: $settings.frameStyle.colour) {
                    ForEach(FrameStyle.Colour.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Toggle("Thin line around the photo", isOn: $settings.frameStyle.keyline)
                if settings.frameStyle.kind == .polaroid || settings.frameStyle.kind == .gallery {
                    Toggle("Caption under the photo", isOn: $settings.frameStyle.caption)
                    Text("Its title and date, when the photo has them. Photos without either get a plain edge.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Preview another photo…") { chooseSource() }
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).shadow(radius: 1)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(height: 260)
            Text("Preview of \(sourceName). Settings apply to photos sent from now on; ones already on the frame stay as they are. The photo on the frame may already carry a mat, so pick an original to judge fairly.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .task { loadFromFrame() }
        .onChange(of: controller.previewImage) { _ in if sourceName == "the photo on the frame" { loadFromFrame() } }
        .task(id: settings.frameStyle) { await rebuild() }
    }

    private func loadFromFrame() {
        guard let image = controller.previewImage,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        sourceImage = cg
        sourceName = "the photo on the frame"
        Task { await rebuild() }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let cg = loadUprightCGImage(at: url, maxPixelSize: 1700) else { return }
        sourceImage = cg
        sourceName = url.lastPathComponent
        Task { await rebuild() }
    }

    private func rebuild() async {
        guard let source = sourceImage else { return }
        let style = settings.frameStyle
        let width = settings.renderWidth, height = settings.renderHeight
        let crop = settings.cropLandscapePhotos && source.width > source.height
        // The same composition the sender uses, so the preview is what you get.
        preview = await Task.detached(priority: .userInitiated) {
            style.isNone ? NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
                         : FrameStyler.compose(source, style: style, width: width, height: height, fill: crop)
        }.value
    }
}
