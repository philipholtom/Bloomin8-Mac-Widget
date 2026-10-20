import AppKit

/// A random dog photo via the Dog CEO API — no key needed.
public struct DogPhotoSource: ContentSource {
    public init() {}

    public let id = "dogPhoto"
    public let displayName = "Dog Photos"
    public let galleryName = "Dog Photos"

    private let width = 1200
    private let height = 1600

    private struct DogResponse: Decodable {
        let message: String
        let status: String
    }

    public func generateImage(settings: AppSettings) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://dog.ceo/api/breeds/image/random")!)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Dog CEO API returned an error")
        }
        let decoded = try JSONDecoder().decode(DogResponse.self, from: data)
        guard decoded.status == "success", let imageURL = URL(string: decoded.message) else {
            throw ContentSourceError.message("No dog photo in the response")
        }

        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard let cgImage = loadUprightCGImage(data: imageData) else {
            throw ContentSourceError.message("Couldn't decode the dog photo")
        }
        guard let framed = renderFilled(cgImage: cgImage, width: width, height: height),
              let jpeg = ImageCanvas.jpegData(framed)
        else {
            throw ContentSourceError.message("Couldn't render the dog photo")
        }
        return jpeg
    }
}
