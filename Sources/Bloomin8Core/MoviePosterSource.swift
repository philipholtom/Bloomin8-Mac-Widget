import AppKit

/// Which films the Movie Posters source draws from.
public enum MoviePosterMode: String, CaseIterable, Identifiable, Codable {
    case popular, topRated, nowPlaying, onThisDay, search

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .popular: return "Popular films"
        case .topRated: return "Top-rated films"
        case .nowPlaying: return "Now in cinemas"
        case .onThisDay: return "Released on this day"
        case .search: return "A title I search for"
        }
    }
}

/// How the Movie Posters source picks a film. Stored once for both products.
public struct MoviePosterOptions: Codable, Equatable {
    public var mode: MoviePosterMode = .popular
    /// First year of the decade to draw from (1980 = the 1980s); 0 = any year.
    /// Applies to the popular and top-rated modes.
    public var decadeStart: Int = 0
    /// TMDB genre id; 0 = any. Applies to the popular and top-rated modes.
    public var genreID: Int = 0
    /// For `.search`: the film title to look up.
    public var query: String = ""

    public init() {}

    private static let defaultsKey = "moviePosterOptions"

    public static func stored() -> MoviePosterOptions {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(MoviePosterOptions.self, from: data) else { return MoviePosterOptions() }
        return decoded
    }

    public static func store(_ options: MoviePosterOptions, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: defaultsKey) }
    }
}

public enum MovieGenres {
    /// TMDB's movie genre ids.
    public static let all: [(id: Int, name: String)] = [
        (28, "Action"), (12, "Adventure"), (16, "Animation"), (35, "Comedy"), (80, "Crime"),
        (99, "Documentary"), (18, "Drama"), (10751, "Family"), (14, "Fantasy"), (36, "History"),
        (27, "Horror"), (10402, "Music"), (9648, "Mystery"), (10749, "Romance"),
        (878, "Science Fiction"), (53, "Thriller"), (10752, "War"), (37, "Western")
    ]
}

/// Movie posters from The Movie Database (themoviedb.org), with a museum card
/// for the film. Needs the user's own free TMDB key (Settings → Content).
/// Posters are 2:3 and the frame 3:4, so they're shown whole with thin black
/// bars at the sides rather than cropped.
public struct MoviePosterSource: TodayContentSource {
    public init() {}

    public let id = "moviePosters"
    public let displayName = "Movie Posters"
    public let galleryName = "Movie Posters"
    public let todayButtonTitle = "Film released today"

    static let keyAccount = "tmdb-api-key"
    /// `BLOOMING8_TMDB_API_BASE` / `BLOOMING8_TMDB_IMAGE_BASE` point the source
    /// at a stand-in server, for tests only.
    private static var apiBase: String { ProcessInfo.processInfo.environment["BLOOMING8_TMDB_API_BASE"] ?? "https://api.themoviedb.org" }
    private static var imageBase: String { ProcessInfo.processInfo.environment["BLOOMING8_TMDB_IMAGE_BASE"] ?? "https://image.tmdb.org" }
    private let width = 1200
    private let height = 1600

    // MARK: - Public entry points

    public func generateImage(settings: AppSettings) async throws -> Data {
        try await generateImageAndCard(settings: settings).data
    }

    public func generateImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        try await render(movie: try await pick(options: MoviePosterOptions.stored()))
    }

    public func generateTodayImage(settings: AppSettings) async throws -> Data {
        try await generateTodayImageAndCard(settings: settings).data
    }

    /// A film released on today's date (any earlier year).
    public func generateTodayImageAndCard(settings: AppSettings) async throws -> GeneratedContent {
        var options = MoviePosterOptions.stored()
        options.mode = .onThisDay
        return try await render(movie: try await pick(options: options))
    }

    // MARK: - TMDB models

    private struct ListResponse: Decodable {
        let results: [Movie]
        let totalPages: Int?
        enum CodingKeys: String, CodingKey { case results; case totalPages = "total_pages" }
    }

    private struct Movie: Decodable {
        let id: Int
        let title: String?
        let posterPath: String?
        enum CodingKeys: String, CodingKey { case id, title; case posterPath = "poster_path" }
    }

    struct Detail: Decodable {
        let title: String?
        let tagline: String?
        let overview: String?
        let releaseDate: String?
        let runtime: Int?
        let posterPath: String?
        let genres: [Genre]?
        let credits: Credits?
        struct Genre: Decodable { let name: String }
        struct Credits: Decodable { let crew: [Crew]? }
        struct Crew: Decodable { let job: String?; let name: String? }
        enum CodingKeys: String, CodingKey {
            case title, tagline, overview, runtime, genres, credits
            case releaseDate = "release_date"
            case posterPath = "poster_path"
        }
    }

    // MARK: - Picking a film

    private func pick(options: MoviePosterOptions) async throws -> Movie {
        switch options.mode {
        case .search:
            let query = options.query.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                throw ContentSourceError.message("Type a film title in Settings → Content → Movie Posters first.")
            }
            let list: ListResponse = try await get("/3/search/movie", [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")])
            guard let found = list.results.first(where: { $0.posterPath != nil }) else {
                throw ContentSourceError.message("No film with a poster matched “\(query)”.")
            }
            return found

        case .nowPlaying:
            let region = Locale.current.region?.identifier ?? "US"
            let first: ListResponse = try await get("/3/movie/now_playing", [URLQueryItem(name: "region", value: region), URLQueryItem(name: "page", value: "1")])
            let page = Int.random(in: 1...max(1, min(first.totalPages ?? 1, 5)))
            let list: ListResponse = page == 1 ? first : try await get("/3/movie/now_playing", [URLQueryItem(name: "region", value: region), URLQueryItem(name: "page", value: "\(page)")])
            return try choose(from: list.results)

        case .onThisDay:
            return try await pickReleasedOnThisDay()

        case .popular, .topRated:
            var items = [
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "sort_by", value: options.mode == .popular ? "popularity.desc" : "vote_average.desc"),
                URLQueryItem(name: "vote_count.gte", value: options.mode == .popular ? "300" : "2000")
            ]
            if options.genreID != 0 { items.append(URLQueryItem(name: "with_genres", value: "\(options.genreID)")) }
            if options.decadeStart != 0 {
                items.append(URLQueryItem(name: "primary_release_date.gte", value: "\(options.decadeStart)-01-01"))
                items.append(URLQueryItem(name: "primary_release_date.lte", value: "\(options.decadeStart + 9)-12-31"))
            }
            // Page 1 says how many pages there are; then a random page of the first few.
            let first: ListResponse = try await get("/3/discover/movie", items + [URLQueryItem(name: "page", value: "1")])
            let limit = max(1, min(first.totalPages ?? 1, options.mode == .popular ? 25 : 12))
            let page = Int.random(in: 1...limit)
            let list: ListResponse = page == 1 ? first : try await get("/3/discover/movie", items + [URLQueryItem(name: "page", value: "\(page)")])
            return try choose(from: list.results)
        }
    }

    /// A film released today's month and day in a random earlier year.
    private func pickReleasedOnThisDay() async throws -> Movie {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let thisYear = parts.year ?? 2026
        let monthDay = String(format: "%02d-%02d", parts.month ?? 1, parts.day ?? 1)
        var years = Array(1950..<thisYear).shuffled()
        years = Array(years.prefix(25))
        for year in years {
            let date = "\(year)-\(monthDay)"
            let items = [
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "sort_by", value: "popularity.desc"),
                URLQueryItem(name: "vote_count.gte", value: "50"),
                URLQueryItem(name: "primary_release_date.gte", value: date),
                URLQueryItem(name: "primary_release_date.lte", value: date)
            ]
            do {
                let list: ListResponse = try await get("/3/discover/movie", items)
                if let found = list.results.first(where: { $0.posterPath != nil }) { return found }
            } catch let error as ContentSourceError {
                throw error // a missing/rejected key or a TMDB error: say so, don't keep trying
            } catch {
                continue // a network hiccup on one year: try another
            }
        }
        throw ContentSourceError.message("Couldn't find a film released on this date. Try again, or pick another mode.")
    }

    private func choose(from movies: [Movie]) throws -> Movie {
        guard let movie = movies.filter({ $0.posterPath != nil }).randomElement() else {
            throw ContentSourceError.message("No films with a poster matched those choices — try widening the decade or genre.")
        }
        return movie
    }

    // MARK: - Rendering

    private func render(movie: Movie) async throws -> GeneratedContent {
        let detail: Detail = try await get("/3/movie/\(movie.id)", [URLQueryItem(name: "append_to_response", value: "credits")])
        guard let posterPath = detail.posterPath ?? movie.posterPath,
              let imageURL = URL(string: "\(Self.imageBase)/t/p/original\(posterPath)")
        else { throw ContentSourceError.message("That film has no poster.") }

        let (data, response) = try await URLSession.shared.data(from: imageURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let cgImage = loadUprightCGImage(data: data)
        else { throw ContentSourceError.message("Couldn't download the poster.") }
        guard let framed = renderLetterboxed(cgImage: cgImage, width: width, height: height, background: .black),
              let jpeg = ImageCanvas.jpegData(framed)
        else { throw ContentSourceError.message("Couldn't render the poster.") }
        return GeneratedContent(data: jpeg, card: Self.museumCard(for: detail, fallbackTitle: movie.title))
    }

    /// Title and year on the first line, the director under it, the release
    /// date, genres and running time, then the tagline (or the opening of the
    /// plot) as the notes.
    static func museumCard(for detail: Detail, fallbackTitle: String?) -> MuseumCard {
        var card = MuseumCard()
        let title = TextCleaning.decodeHTMLEntities(detail.title ?? fallbackTitle ?? "")
        let year = detail.releaseDate.flatMap { $0.split(separator: "-").first.map(String.init) }
        card.title = year.map { "\(title) (\($0))" } ?? title

        if let director = detail.credits?.crew?.first(where: { $0.job == "Director" })?.name {
            card.place = "Directed by \(director)"
        }

        if let released = detail.releaseDate {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd"
            if let date = parser.date(from: released) {
                let display = DateFormatter()
                display.setLocalizedDateFormatFromTemplate("d MMM yyyy")
                card.date = display.string(from: date)
            }
        }

        var facts: [String] = []
        if let genres = detail.genres?.prefix(3).map(\.name), !genres.isEmpty { facts.append(genres.joined(separator: ", ")) }
        if let runtime = detail.runtime, runtime > 0 { facts.append("\(runtime / 60)h \(runtime % 60)m") }
        card.camera = facts.joined(separator: " · ")

        let tagline = (detail.tagline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = TextCleaning.decodeHTMLEntities(detail.overview ?? "")
        card.notes = APODSource.leadSentences(of: tagline.isEmpty ? overview : tagline, upTo: 150)
        return card.normalized()
    }

    // MARK: - TMDB requests

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        guard let key = SecretStore.read(account: Self.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ContentSourceError.message("Add your free TMDB key in Settings → Content → Movie Posters.")
        }
        var components = URLComponents(string: "\(Self.apiBase)\(path)")!
        var items = query
        // A v3 key goes in the URL; the longer v4 "read access token" is a bearer token.
        let isBearer = key.count > 60
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue(contentSourceUserAgent, forHTTPHeaderField: "User-Agent")
        if isBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ContentSourceError.message("TMDB didn't answer.") }
        if http.statusCode == 401 { throw ContentSourceError.message("TMDB rejected the key — check it in Settings → Content → Movie Posters.") }
        guard (200..<300).contains(http.statusCode) else { throw ContentSourceError.message("TMDB returned an error (\(http.statusCode)).") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
