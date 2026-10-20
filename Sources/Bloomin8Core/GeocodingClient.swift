import Foundation

public struct GeocodingResult: Decodable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let country: String?
    public let admin1: String?

    /// "London, England, United Kingdom" — enough to tell apart the several
    /// places sharing a plain name (there are at least three "London"s in
    /// the geocoder's own results: UK, Ontario, and Ohio).
    public var displayLabel: String {
        [name, admin1, country].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Looks up a place name to coordinates via open-meteo's geocoding API — the
/// same provider already used for weather itself, so no new API key is
/// needed. Lets Settings offer "type a town, pick the right one" instead of
/// requiring the user to already know and hand-enter latitude/longitude.
public enum GeocodingClient {
    public static func search(name: String) async throws -> [GeocodingResult] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "5")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContentSourceError.message("Location lookup returned an error")
        }
        struct SearchResponse: Decodable { let results: [GeocodingResult]? }
        return try JSONDecoder().decode(SearchResponse.self, from: data).results ?? []
    }
}
