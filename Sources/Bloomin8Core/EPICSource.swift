import AppKit

/// The whole Earth, as seen by NOAA's DSCOVR satellite a million miles away
/// — NASA's EPIC (Earth Polychromatic Imaging Camera). Uses
/// epic.gsfc.nasa.gov directly rather than the api.nasa.gov proxy: the
/// latter now just redirects here anyway, and this host needs no API key.
public struct EPICSource: ContentSource {
    public init() {}

    public let id = "epic"
    public let displayName = "Earth from Space"
    public let galleryName = "Earth"

    private let width = 1200
    private let height = 1600

    private struct EPICImage: Decodable {
        let image: String
        let date: String
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://epic.gsfc.nasa.gov/api/natural")!)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("EPIC API returned an error")
        }
        let images = try JSONDecoder().decode([EPICImage].self, from: data)
        guard let picked = images.randomElement() else {
            throw ContentSourceError.message("No EPIC images available right now")
        }

        // `date` looks like "2026-09-15 00:31:45" — the archive path buckets
        // by the date portion only.
        guard let datePart = picked.date.split(separator: " ").first else {
            throw ContentSourceError.message("Unexpected EPIC date format")
        }
        let pathDate = datePart.replacingOccurrences(of: "-", with: "/")
        guard let imageURL = URL(string: "https://epic.gsfc.nasa.gov/archive/natural/\(pathDate)/png/\(picked.image).png") else {
            throw ContentSourceError.message("Couldn't build the EPIC image URL")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard let cgImage = loadUprightCGImage(data: imageData) else {
            throw ContentSourceError.message("Couldn't decode the EPIC image")
        }
        // EPIC's raw frame is a square with the Earth disc inset on a black
        // field — filling rather than letterboxing crops that black margin
        // down instead of adding more bars around an already-square image.
        guard let framed = renderFilled(cgImage: cgImage, width: width, height: height) else {
            throw ContentSourceError.message("Couldn't render the EPIC image")
        }

        let finalImage = ImageCanvas.render(width: width, height: height) {
            drawImage(framed, in: NSRect(x: 0, y: 0, width: width, height: height))
            let font = NSFont(name: "Helvetica-Bold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22)
            drawCentered("Earth · \(datePart)", font: font, color: .white, y: CGFloat(height) - 44, canvasWidth: width)
        }
        guard let finalImage, let jpeg = ImageCanvas.jpegData(finalImage) else {
            throw ContentSourceError.message("Couldn't render the EPIC image")
        }
        return jpeg
    }
}
