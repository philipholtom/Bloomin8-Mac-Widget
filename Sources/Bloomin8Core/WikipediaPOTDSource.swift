import AppKit

/// Wikipedia's daily featured picture, for a random recent date rather than
/// always "today" — same reasoning as APOD: fetching the same one date's
/// picture 3 times in a row for the preview picker would just show 3
/// identical images. Broader subject matter than APOD (wildlife,
/// architecture, art, nature), not just astronomy.
public struct WikipediaPOTDSource: ContentSource {
    public init() {}

    public let id = "wikipediaPOTD"
    public let displayName = "Wikipedia Picture of the Day"
    public let galleryName = "Wikipedia"

    private let width = 1200
    private let height = 1600

    // The real response nests an "image" object inside the top-level
    // "image" field twice over — {title, thumbnail: {source}, image:
    // {source}} — confirmed directly; a flat `image.source` (what the
    // field name alone suggests) doesn't exist and fails to decode.
    private struct FeaturedResponse: Decodable {
        let image: FeaturedImage?
    }

    private struct FeaturedImage: Decodable {
        let title: String
        let image: ImageSource

        struct ImageSource: Decodable {
            let source: String
        }
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        var lastError: Error = ContentSourceError.message("Couldn't reach Wikipedia's featured content API")
        for _ in 0..<4 {
            let date = randomRecentDate()
            var request = URLRequest(url: URL(string: "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/\(date)")!)
            request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    lastError = ContentSourceError.message("Wikipedia's featured content API returned an error")
                    continue
                }
                guard let image = try JSONDecoder().decode(FeaturedResponse.self, from: data).image,
                      let imageURL = URL(string: image.image.source)
                else {
                    continue // that date had no featured picture
                }

                let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                guard let cgImage = loadUprightCGImage(data: imageData) else { continue }
                guard let framed = renderLetterboxed(cgImage: cgImage, width: width, height: height, background: .black) else {
                    continue
                }

                let caption = cleanedTitle(image.title)
                let finalImage = ImageCanvas.render(width: width, height: height) {
                    drawImage(framed, in: NSRect(x: 0, y: 0, width: width, height: height))
                    let font = NSFont(name: "Helvetica", size: 16) ?? NSFont.systemFont(ofSize: 16)
                    let wrapped = wrapText(caption, maxCharsPerLine: 60, maxLines: 2)
                    var y = CGFloat(height) - CGFloat(wrapped.count) * 20 - 16
                    for line in wrapped {
                        drawCentered(line, font: font, color: .white, y: y, canvasWidth: width)
                        y += 20
                    }
                }
                if let finalImage, let jpeg = ImageCanvas.jpegData(finalImage) {
                    return jpeg
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// "File:Some Title (12345).jpg" → "Some Title" — strips the Commons
    /// file-name wrapper this API's `title` field always comes wrapped in.
    private func cleanedTitle(_ raw: String) -> String {
        var title = raw
        if title.hasPrefix("File:") { title.removeFirst(5) }
        if let dot = title.lastIndex(of: ".") { title = String(title[..<dot]) }
        return title.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The featured-content feed has run since 2016 — pick anywhere in that
    /// range up to yesterday (today's entry can be briefly unpublished).
    private func randomRecentDate() -> String {
        var startComponents = DateComponents()
        startComponents.year = 2016
        startComponents.month = 1
        startComponents.day = 1
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: startComponents) ?? Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let days = max(calendar.dateComponents([.day], from: start, to: yesterday).day ?? 0, 0)
        let randomDate = calendar.date(byAdding: .day, value: Int.random(in: 0...days), to: start) ?? yesterday

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.calendar = calendar
        return formatter.string(from: randomDate)
    }
}
