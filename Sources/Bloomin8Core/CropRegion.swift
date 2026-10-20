import Foundation

/// Which part of a photo to keep when fitting it to the frame's canvas: a
/// centre point plus a zoom, both relative to the upright source image, so
/// the same region stays meaningful whatever the canvas shape (portrait or
/// landscape frame). Zoom 1 is the largest canvas-shaped rectangle that
/// fits inside the photo — the same thing a plain "fill" crop keeps — and
/// higher zooms keep a tighter rectangle of the same shape.
public struct CropRegion: Equatable {
    /// Centre of the kept rectangle, 0...1 across the photo's width/height.
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double

    public static let maxZoom: Double = 5
    public static let centered = CropRegion(centerX: 0.5, centerY: 0.5, zoom: 1)

    public init(centerX: Double, centerY: Double, zoom: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
    }

    /// The kept rectangle in source pixels (top-left origin), always fully
    /// inside the image: the zoom is limited to 1...maxZoom and the centre
    /// is pulled in so the rectangle never hangs over an edge.
    public func pixelRect(imageWidth: Double, imageHeight: Double, canvasAspect: Double) -> CGRect {
        let baseWidth: Double
        let baseHeight: Double
        if imageWidth / imageHeight > canvasAspect {
            baseHeight = imageHeight
            baseWidth = imageHeight * canvasAspect
        } else {
            baseWidth = imageWidth
            baseHeight = imageWidth / canvasAspect
        }
        let z = min(max(zoom, 1), Self.maxZoom)
        let width = baseWidth / z
        let height = baseHeight / z
        let cx = min(max(centerX * imageWidth, width / 2), imageWidth - width / 2)
        let cy = min(max(centerY * imageHeight, height / 2), imageHeight - height / 2)
        return CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }

    /// The same region with zoom and centre pulled into their valid ranges.
    public func clamped(imageWidth: Double, imageHeight: Double, canvasAspect: Double) -> CropRegion {
        let rect = pixelRect(imageWidth: imageWidth, imageHeight: imageHeight, canvasAspect: canvasAspect)
        return CropRegion(
            centerX: rect.midX / imageWidth,
            centerY: rect.midY / imageHeight,
            zoom: min(max(zoom, 1), Self.maxZoom)
        )
    }

    /// Stable text form, used to tell one crop of a photo from another when
    /// naming what gets uploaded.
    public var keyDescription: String {
        String(format: "%.4f,%.4f,%.3f", centerX, centerY, zoom)
    }
}
