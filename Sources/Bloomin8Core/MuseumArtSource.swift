import AppKit

/// A random public-domain painting from the Metropolitan Museum of Art's
/// open-access collection — no API key needed. Search first for object IDs
/// (that endpoint doesn't include images), then fetch a random one's detail
/// to get the actual image, retrying if that particular object turns out to
/// have no public-domain image after all — the search's `hasImages` filter
/// isn't perfectly reliable in practice.
public struct MuseumArtSource: ContentSource {
    public init() {}

    public let id = "museumArt"
    public let displayName = "Museum Art"
    public let galleryName = "Museum"

    private let width = 1200
    private let height = 1600

    private struct SearchResponse: Decodable {
        let total: Int?
        let objectIDs: [Int]?
    }

    private struct ObjectDetail: Decodable {
        let title: String
        let artistDisplayName: String
        let primaryImage: String
        let isPublicDomain: Bool
    }

    /// The Met retired `/v1/search` on 2026-10-01 (it now answers 410 Gone).
    /// `/v1.1/search` is paginated by `offset`/`limit` and can't page past
    /// 10,000 results, so a random page is picked inside that window.
    private static let pageSize = 50
    private static let maxPagingWindow = 10_000

    private func searchPage(query: String, offset: Int) async throws -> SearchResponse {
        var components = URLComponents(string: "https://collectionapi.metmuseum.org/public/collection/v1.1/search")!
        components.queryItems = [
            URLQueryItem(name: "hasImages", value: "true"),
            URLQueryItem(name: "isPublicDomain", value: "true"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Met Museum search returned an error")
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        // A handful of broad, reliably-populated query terms — the search
        // endpoint requires some query, there's no "browse everything".
        let query = ["painting", "landscape", "portrait", "still life", "watercolor"].randomElement() ?? "painting"

        // Guess a random page; if that's past the end of a smaller result
        // set, the response still reports `total`, so retry inside it.
        let firstGuess = try await searchPage(query: query, offset: Int.random(in: 0..<(Self.maxPagingWindow - Self.pageSize)))
        var ids = firstGuess.objectIDs ?? []
        if ids.isEmpty, let total = firstGuess.total, total > 0 {
            let upper = max(1, min(total, Self.maxPagingWindow) - Self.pageSize)
            ids = try await searchPage(query: query, offset: Int.random(in: 0..<upper)).objectIDs ?? []
        }
        guard !ids.isEmpty else {
            throw ContentSourceError.message("No Met Museum results for '\(query)'")
        }

        var lastError: Error = ContentSourceError.message("Couldn't find a public-domain image")
        for objectID in ids.shuffled().prefix(6) {
            do {
                let detailURL = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(objectID)")!
                let (detailData, detailResponse) = try await URLSession.shared.data(from: detailURL)
                guard let http = detailResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                let object = try JSONDecoder().decode(ObjectDetail.self, from: detailData)
                guard object.isPublicDomain, !object.primaryImage.isEmpty, let imageURL = URL(string: object.primaryImage) else {
                    continue
                }

                let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                guard let cgImage = loadUprightCGImage(data: imageData) else { continue }
                guard let framed = renderLetterboxed(cgImage: cgImage, width: width, height: height, background: .black) else {
                    continue
                }

                let caption = object.artistDisplayName.isEmpty ? object.title : "\(object.title) — \(object.artistDisplayName)"
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
}
