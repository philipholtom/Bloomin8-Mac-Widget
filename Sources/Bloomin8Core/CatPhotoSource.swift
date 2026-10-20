import AppKit

/// A random cat photo via TheCatAPI — no key needed. Uploads to its own
/// "Cat Photos" gallery, deliberately not "Cats": that name is already used
/// for the user's own personal cat photos elsewhere in this app, and these
/// aren't those.
public struct CatPhotoSource: ContentSource {
    public init() {}

    public let id = "catPhoto"
    public let displayName = "Cat Photos"
    public let galleryName = "Cat Photos"

    private let width = 1200
    private let height = 1600

    private struct CatImage: Decodable {
        let url: String
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.thecatapi.com/v1/images/search")!)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("TheCatAPI returned an error")
        }
        guard let picked = try JSONDecoder().decode([CatImage].self, from: data).first,
              let imageURL = URL(string: picked.url)
        else {
            throw ContentSourceError.message("No cat photo in the response")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard let cgImage = loadUprightCGImage(data: imageData) else {
            throw ContentSourceError.message("Couldn't decode the cat photo")
        }
        // Filled, not letterboxed: these are ordinary snapshots (all sorts
        // of aspect ratios), and cropping in a bit reads better on a frame
        // than thick black bars around a small cat photo.
        guard let framed = renderFilled(cgImage: cgImage, width: width, height: height),
              let jpeg = ImageCanvas.jpegData(framed)
        else {
            throw ContentSourceError.message("Couldn't render the cat photo")
        }
        return jpeg
    }
}
