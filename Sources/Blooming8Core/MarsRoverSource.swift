import AppKit

/// Recent raw images from NASA's Mars rovers, via JPL's own raw-images feed
/// (mars.nasa.gov) rather than api.nasa.gov's "Mars Rover Photos" API —
/// confirmed directly that the latter is dead (its Heroku backend returns
/// "No such app"), while this one, JPL's own, is still live.
public struct MarsRoverSource: ContentSource {
    public init() {}

    public let id = "marsRover"
    public let displayName = "Mars Rover"
    public let galleryName = "Mars"

    private let width = 1200
    private let height = 1600

    private struct FeedResponse: Decodable {
        let images: [RawImage]
    }

    private struct RawImage: Decodable {
        let sol: Int
        let imageFiles: ImageFiles
        let title: String?
        let caption: String?
        let site: Int?
        let dateTakenUTC: String?
        let dateTakenMars: String?
        let credit: String?

        enum CodingKeys: String, CodingKey {
            case sol, title, caption, site, credit
            case imageFiles = "image_files"
            case dateTakenUTC = "date_taken_utc"
            case dateTakenMars = "date_taken_mars"
        }

        struct ImageFiles: Decodable {
            let large: String?
            let mediumImage: String?
            enum CodingKeys: String, CodingKey {
                case large
                case mediumImage = "medium"
            }
        }
    }

    // Perseverance only — confirmed directly against the live API.
    // Curiosity's "msl" category is recognized (echoes "mission":"msl" in
    // the response) but always returns zero images ("No more images.",
    // total_images: 0), and no alternate slug for it (curiosity,
    // mars-science-laboratory, msl-raw-images, MSL) resolves either — its
    // raw images apparently live behind a different, undiscovered path.
    private static let rover = "mars2020"

    public func generateImage(settings: AppSettings) async throws -> Data {
        try await generateImageAndCard(settings: settings).data
    }

    public func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        var components = URLComponents(string: "https://mars.nasa.gov/rss/api/")!
        components.queryItems = [
            URLQueryItem(name: "feed", value: "raw_images"),
            URLQueryItem(name: "category", value: Self.rover),
            URLQueryItem(name: "feedtype", value: "json"),
            URLQueryItem(name: "num", value: "50"),
            URLQueryItem(name: "page", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Mars rover feed returned an error")
        }
        let feed = try JSONDecoder().decode(FeedResponse.self, from: data)
        let candidates = feed.images.filter { $0.imageFiles.large != nil || $0.imageFiles.mediumImage != nil }
        guard let picked = candidates.randomElement(),
              let urlString = picked.imageFiles.large ?? picked.imageFiles.mediumImage,
              let imageURL = URL(string: urlString)
        else {
            throw ContentSourceError.message("No usable images in the Mars rover feed")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard let cgImage = loadUprightCGImage(data: imageData) else {
            throw ContentSourceError.message("Couldn't decode the Mars rover image")
        }
        guard let framed = renderLetterboxed(cgImage: cgImage, width: width, height: height, background: .black) else {
            throw ContentSourceError.message("Couldn't render the Mars rover image")
        }

        let caption = "Perseverance · Sol \(picked.sol)"
        let finalImage = ImageCanvas.render(width: width, height: height) {
            drawImage(framed, in: NSRect(x: 0, y: 0, width: width, height: height))
            let font = NSFont(name: "Helvetica-Bold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22)
            drawCentered(caption, font: font, color: .white, y: CGFloat(height) - 44, canvasWidth: width)
        }
        guard let finalImage, let jpeg = ImageCanvas.jpegData(finalImage) else {
            throw ContentSourceError.message("Couldn't render the Mars rover image")
        }
        return GeneratedContent(data: jpeg, card: Self.museumCard(for: picked))
    }

    /// The museum card for a raw image: rover and sol as the title, where and
    /// when it was taken, which camera took it, and what that camera is for.
    private static func museumCard(for image: RawImage) -> MuseumCard {
        var card = MuseumCard()
        card.title = "Perseverance rover · Sol \(image.sol)"
        card.place = image.site.map { "Mars · Site \($0)" } ?? "Mars"

        // Earth date: "2026-10-15T21:26:25.500" (UTC) → "15 Oct 2026".
        if let utc = image.dateTakenUTC, let day = utc.split(separator: "T").first {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = TimeZone(identifier: "UTC")
            if let date = parser.date(from: String(day)) {
                let display = DateFormatter()
                display.setLocalizedDateFormatFromTemplate("d MMM yyyy")
                display.timeZone = TimeZone(identifier: "UTC")
                card.date = display.string(from: date)
            }
        }

        // "Mars Perseverance Sol 2010: Right Navigation Camera (Navcam)" → the part after the colon.
        if let title = image.title, let colon = title.firstIndex(of: ":") {
            card.camera = String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        var notes: [String] = []
        // "Sol-02010M10:34:02.514" → "10:34 local Mars time".
        if let mars = image.dateTakenMars, let time = mars.split(separator: "M").last, time.count >= 5 {
            notes.append("Taken at \(time.prefix(5)) local Mars time.")
        }
        // The caption's camera description, e.g. "The camera is located high
        // on the rover's mast and aids in driving."
        if let caption = image.caption,
           let range = caption.range(of: "The camera[^.]*\\.", options: .regularExpression) {
            notes.append(String(caption[range]))
        }
        card.notes = APODSource.leadSentences(of: notes.joined(separator: " "), upTo: 150)
        return card.normalized()
    }
}
