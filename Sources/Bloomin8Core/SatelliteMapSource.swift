import AppKit

/// A true-color satellite view of the sky over your own location, via
/// NASA's GIBS Worldview snapshot service — it composes the requested
/// region server-side into one image at the exact size asked for, so this
/// needs no client-side map-tile stitching. No API key needed. Reuses the
/// same latitude/longitude already configured for the text Weather source
/// (Settings → Generated Content), rather than adding a second place to
/// set a location.
public struct SatelliteMapSource: ContentSource {
    public init() {}

    public let id = "satelliteMap"
    public let displayName = "Satellite View"
    public let galleryName = "Satellite"

    private let width = 1200
    private let height = 1600
    /// Degrees of longitude/latitude either side of the configured point —
    /// wide enough to show real weather-system structure (fronts, cloud
    /// bands), not just the sky directly overhead.
    private let halfSpan: Double = 6

    /// Four instruments GIBS serves true-color imagery from. The scene over
    /// one location can look near-identical day to day if it's always the
    /// same instrument, so which one is used is randomized per generation —
    /// but the location and "most recent available" behavior stay exactly
    /// as configured, unlike a randomized date or offset.
    private static let layers = [
        "VIIRS_SNPP_CorrectedReflectance_TrueColor",
        "VIIRS_NOAA20_CorrectedReflectance_TrueColor",
        "MODIS_Terra_CorrectedReflectance_TrueColor",
        "MODIS_Aqua_CorrectedReflectance_TrueColor"
    ]

    public func generateImage(settings: AppSettings) async throws -> Data {
        guard settings.weatherLatitude != 0 || settings.weatherLongitude != 0 else {
            throw ContentSourceError.message("Set your location under Settings → Generated Content → Weather first")
        }

        let lat = settings.weatherLatitude
        let lon = settings.weatherLongitude
        // GIBS's snapshot service follows WMS 1.3 axis order for EPSG:4326,
        // which is lat,lon — not lon,lat like the coordinates themselves.
        // Getting this backwards silently returns a real (non-placeholder)
        // image from entirely the wrong part of the world, e.g. a UK
        // location landing in the Indian Ocean.
        let bbox = "\(lat - halfSpan),\(lon - halfSpan),\(lat + halfSpan),\(lon + halfSpan)"

        var lastError: Error = ContentSourceError.message("Couldn't reach the satellite imagery service")
        // For the randomly picked instrument, try the most recent day first
        // and fall further back only if that day's pass wasn't composited
        // yet; only move on to another instrument if this one has no recent
        // data at all.
        for layer in Self.layers.shuffled() {
            for daysAgo in 0...3 {
                let date = dateString(daysAgo: daysAgo)
                var components = URLComponents(string: "https://wvs.earthdata.nasa.gov/api/v1/snapshot")!
                components.queryItems = [
                    URLQueryItem(name: "REQUEST", value: "GetSnapshot"),
                    URLQueryItem(name: "LAYERS", value: layer),
                    URLQueryItem(name: "CRS", value: "EPSG:4326"),
                    URLQueryItem(name: "TIME", value: date),
                    URLQueryItem(name: "WRAP", value: "DAY"),
                    URLQueryItem(name: "BBOX", value: bbox),
                    URLQueryItem(name: "FORMAT", value: "image/jpeg"),
                    URLQueryItem(name: "WIDTH", value: String(width)),
                    URLQueryItem(name: "HEIGHT", value: String(height))
                ]
                do {
                    let (data, response) = try await URLSession.shared.data(from: components.url!)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        lastError = ContentSourceError.message("Satellite imagery service returned an error")
                        continue
                    }
                    // A failed/empty composite still comes back 200 with a
                    // tiny placeholder — a real 1200x1600 true-color JPEG is
                    // never this small.
                    guard data.count > 20_000 else {
                        lastError = ContentSourceError.message("No satellite imagery available for that date")
                        continue
                    }
                    guard let cgImage = loadUprightCGImage(data: data) else {
                        lastError = ContentSourceError.message("Couldn't decode the satellite image")
                        continue
                    }
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    guard let jpeg = ImageCanvas.jpegData(image) else {
                        lastError = ContentSourceError.message("Couldn't render the satellite image")
                        continue
                    }
                    return jpeg
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private func dateString(daysAgo: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        return formatter.string(from: date)
    }
}
