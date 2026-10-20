import Bloomin8Core
import AppKit
import SwiftUI

/// Picks which part of a photo the frame will show: drag the box to move it,
/// use the slider to zoom in. The box always has the frame's own shape
/// (portrait or landscape), so what's inside it is exactly what gets sent.
struct CropSheet: View {
    let imageURL: URL
    /// The frame canvas's width / height (orientation already applied).
    let canvasAspect: Double
    let onApply: (CropRegion) -> Void
    /// Given for a local photo, so the preview can be blurred if it comes
    /// from locked content; nil for photos from outside the app's locked areas.
    let settings: AppSettings?

    @Environment(\.dismiss) private var dismiss
    @State private var cgImage: CGImage?
    @State private var crop: CropRegion
    @State private var dragStart: CropRegion?
    @State private var loadFailed = false

    private let previewSize = CGSize(width: 640, height: 440)

    init(imageURL: URL, canvasAspect: Double, initial: CropRegion = .centered, settings: AppSettings? = nil, onApply: @escaping (CropRegion) -> Void) {
        self.imageURL = imageURL
        self.canvasAspect = canvasAspect
        self.onApply = onApply
        self.settings = settings
        _crop = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Crop")
                    .font(.headline)
                Spacer()
                if let settings {
                    PrivacyBlurButton(settings: settings, isLocalFile: true)
                }
            }
            Text("Drag the box to choose what the frame shows. Zoom to keep a tighter area.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                if let cgImage {
                    preview(for: cgImage)
                } else if loadFailed {
                    Text("Couldn't read this photo.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: zoomBinding, in: 1...CropRegion.maxZoom)
                    .disabled(cgImage == nil)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }

            HStack {
                Button("Reset") { crop = .centered }
                    .disabled(cgImage == nil || crop == .centered)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use This Crop") {
                    onApply(clampedCrop)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(cgImage == nil)
            }
        }
        .padding(20)
        .frame(width: previewSize.width + 40)
        .task {
            let url = imageURL
            let loaded = await Task.detached { loadUprightCGImage(at: url) }.value
            cgImage = loaded
            loadFailed = loaded == nil
        }
    }

    /// The photo scaled to fit the preview area, dimmed everywhere outside
    /// the crop box.
    private func preview(for cgImage: CGImage) -> some View {
        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)
        let scale = min(previewSize.width / imageWidth, previewSize.height / imageHeight)
        let shown = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let box = crop.pixelRect(imageWidth: imageWidth, imageHeight: imageHeight, canvasAspect: canvasAspect)
        let boxOnScreen = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)

        return ZStack(alignment: .topLeading) {
            PrivacyImage(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), settings: settings, isLocalFile: true)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .privacyBlurIfLocal(settings: settings)

            Path { path in
                path.addRect(CGRect(origin: .zero, size: shown))
                path.addRect(boxOnScreen)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: boxOnScreen.width, height: boxOnScreen.height)
                .offset(x: boxOnScreen.minX, y: boxOnScreen.minY)
                .allowsHitTesting(false)
        }
        .frame(width: shown.width, height: shown.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? crop
                    dragStart = start
                    crop = CropRegion(
                        centerX: start.centerX + Double(value.translation.width) / shown.width,
                        centerY: start.centerY + Double(value.translation.height) / shown.height,
                        zoom: start.zoom
                    )
                    crop = clampedCrop
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private var clampedCrop: CropRegion {
        guard let cgImage else { return crop }
        return crop.clamped(imageWidth: Double(cgImage.width), imageHeight: Double(cgImage.height), canvasAspect: canvasAspect)
    }

    /// Zooming in re-clamps the centre: a box that fit at zoom 1 against an
    /// edge is still against that edge, not hanging past it, once it shrinks.
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { crop.zoom },
            set: { newZoom in
                crop.zoom = newZoom
                crop = clampedCrop
            }
        )
    }
}
