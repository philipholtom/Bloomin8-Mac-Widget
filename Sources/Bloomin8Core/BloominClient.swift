import Foundation

public struct DeviceInfo: Decodable {
    public let name: String?
    public let image: String?
    public let gallery: String?
    public let battery: Int?
    public let sleepDuration: Int?
    public let maxIdle: Int?
    public let idxWakeSens: Int?
    /// The frame's actual canvas size in pixels (e.g. 1200x1600 for a
    /// portrait model) — lets rendering adapt to whatever frame is
    /// connected instead of assuming portrait 1200x1600 everywhere.
    public let width: Int?
    public let height: Int?
    // Read-only status the frame reports (see the API docs' GET /deviceInfo).
    public let version: String?
    public let sn: String?
    public let screenModel: String?
    public let totalSize: Int?
    public let freeSize: Int?
    /// 0 = not connected, 2 = Wi-Fi.
    public let networkType: Int?
    public let staRSSI: Int?
    public let staSSID: String?
    public let staIP: String?
    /// Unix time of the frame's next scheduled wake-up.
    public let nextTime: Int?
    public let playlist: String?
    /// 0 = single image, 1 = gallery slideshow, 2 = playlist.
    public let playType: Int?
    public let playDuration: Int?
    public let beepOn: Bool?
    public let silenceOn: Bool?

    public enum CodingKeys: String, CodingKey {
        case name, image, gallery, battery, width, height, version, sn, playlist
        case screenModel = "screen_model"
        case totalSize = "total_size"
        case freeSize = "free_size"
        case networkType = "network_type"
        case staRSSI = "sta_rssi"
        case staSSID = "sta_ssid"
        case staIP = "sta_ip"
        case nextTime = "next_time"
        case playType = "play_type"
        case playDuration = "play_duration"
        case beepOn = "beep_on"
        case silenceOn = "silence_on"
        case sleepDuration = "sleep_duration"
        case maxIdle = "max_idle"
        case idxWakeSens = "idx_wake_sens"
    }
}

public struct GalleryEntry: Decodable {
    public let name: String
}

public struct GalleryImage: Decodable {
    public let name: String
}

public struct GalleryListing: Decodable {
    public let data: [GalleryImage]
    public let cursorNext: String?
    public let more: Bool?

    public enum CodingKeys: String, CodingKey {
        case data
        case cursorNext = "cursor_next"
        case more
    }
}

public enum BloominError: LocalizedError {
    case noDeviceIP
    case badResponse(String)
    case http(Int)
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .noDeviceIP:
            return "Set the frame's IP address first."
        case .badResponse(let detail):
            return "Unexpected response: \(detail)"
        case .http(let code):
            return "Frame returned HTTP \(code)."
        case .busy(let reason):
            return "Frame is busy (\(reason))."
        }
    }
}

public final class BloominClient {
    private let session: URLSession
    /// A separate session just for `uploadImage`, with much more generous
    /// timeouts than `session`'s. The frame's own device log showed
    /// `Start upload: ...` immediately followed by `Upload aborted by
    /// client` — this client, not the frame, was the one giving up: the
    /// main session's 8s/15s timeouts are fine for a lightweight GET against
    /// this frame's known-slow embedded server, but too short for actually
    /// transferring an image (several hundred KB to ~1MB) to it, so a
    /// perfectly healthy in-flight upload was being cancelled out from
    /// under itself before the frame finished accepting it. Both
    /// `timeoutIntervalForRequest` and `timeoutIntervalForResource` are
    /// session-level configuration, not overridable per-request, hence a
    /// second session rather than a per-request override.
    private let uploadSession: URLSession
    /// For listing a gallery and downloading images. Measured against the
    /// real frame: listing pages get slower the further into a gallery they
    /// are (a 166-photo gallery took 1.8s, 4.5s, 8.8s, 8.7s for its four
    /// pages), which the default 8s limit turned into a failed load.
    private let readSession: URLSession
    /// A whole batch rides one request, so it gets a much longer budget.
    private let batchUploadSession: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)

        // Measured directly against the real frame: a 1.6MB JPEG upload
        // (deliberately worst-case — high-entropy noise compresses poorly,
        // larger than this app's own renders typically are) took 40s end to
        // end. 90s/120s leaves real headroom above that rather than merely
        // clearing the one measurement.
        let uploadConfig = URLSessionConfiguration.ephemeral
        uploadConfig.timeoutIntervalForRequest = 90
        uploadConfig.timeoutIntervalForResource = 120
        uploadSession = URLSession(configuration: uploadConfig)

        let readConfig = URLSessionConfiguration.ephemeral
        readConfig.timeoutIntervalForRequest = 45
        readConfig.timeoutIntervalForResource = 90
        readSession = URLSession(configuration: readConfig)

        let batchConfig = URLSessionConfiguration.ephemeral
        batchConfig.timeoutIntervalForRequest = 180
        batchConfig.timeoutIntervalForResource = 600
        batchUploadSession = URLSession(configuration: batchConfig)
    }

    private func baseURL(ip: String) throws -> String {
        guard !ip.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BloominError.noDeviceIP
        }
        return "http://\(ip.trimmingCharacters(in: .whitespaces))"
    }

    public func fetchDeviceInfo(ip: String) async throws -> DeviceInfo {
        let url = try URL(string: baseURL(ip: ip) + "/deviceInfo")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        return try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    public func fetchGalleryList(ip: String) async throws -> [String] {
        let url = try URL(string: baseURL(ip: ip) + "/gallery/list")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        let entries = try JSONDecoder().decode([GalleryEntry].self, from: data)
        return entries.map { $0.name }
    }

    /// Fetches every image in a gallery by walking the device's cursor-based
    /// pagination (`full=1`). The cursor from one page's `cursor_next` is
    /// fed back in via a `cursor` query parameter (undocumented, found by
    /// probing the device directly) to fetch the next page.
    public func fetchAllImages(ip: String, gallery: String) async throws -> [String] {
        var allNames: [String] = []
        try await walkGalleryImages(ip: ip, gallery: gallery) { allNames.append(contentsOf: $0) }
        return allNames
    }

    /// Walks a gallery page by page, handing each page's new names to
    /// `onPage` as soon as it arrives rather than only at the end — so a big
    /// or slow gallery can start showing photos immediately, and a failure on
    /// a late page doesn't throw away the earlier ones (they've already been
    /// delivered). Throws if a page fails; pages before it were still reported.
    public func walkGalleryImages(ip: String, gallery: String, onPage: @MainActor ([String]) -> Void) async throws {
        var seen = Set<String>()
        var cursor: String? = nil
        var pageCount = 0
        let maxPages = 200 // safety cap: ~10,000 images at 51/page

        while pageCount < maxPages {
            pageCount += 1
            var components = URLComponents(string: try baseURL(ip: ip) + "/gallery")!
            var queryItems = [
                URLQueryItem(name: "gallery_name", value: gallery),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "51"),
                URLQueryItem(name: "full", value: "1")
            ]
            if let cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components.queryItems = queryItems
            let (data, response) = try await readSession.data(from: components.url!)
            try checkStatus(response)
            let listing = try JSONDecoder().decode(GalleryListing.self, from: data)

            let newNames = listing.data.map { $0.name }.filter { !seen.contains($0) }
            if newNames.isEmpty { break }
            newNames.forEach { seen.insert($0) }
            await onPage(newNames)

            guard listing.more == true, let next = listing.cursorNext, next != cursor else {
                break
            }
            cursor = next
        }
    }

    private struct ShowResponse: Decodable {
        let status: String?
        let msg: String?
    }

    /// The frame can reject a /show call while it's still drawing the
    /// previous one — observed both as HTTP 500 and, inconsistently, as
    /// HTTP 200 with `{"status":"fail","msg":"DRAWING"}` in the body. Check
    /// both shapes so callers can reliably detect and retry on this.
    public func show(ip: String, imagePath: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/show")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["play_type": 0, "image": imagePath]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let decoded = try? JSONDecoder().decode(ShowResponse.self, from: data)
        if decoded?.status == "fail" {
            throw BloominError.busy(decoded?.msg ?? "unknown reason")
        }
        try checkStatus(response)
    }

    /// Immediately displays the next image in the frame's current playback
    /// queue (only meaningful when it's in gallery-slideshow or playlist
    /// mode, not single-image mode).
    public func showNext(ip: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/showNext")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Starts a gallery slideshow: cycles through `gallery`'s images every
    /// `durationSeconds`, advancing automatically on-device.
    public func startSlideshow(ip: String, gallery: String, durationSeconds: Int) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/show")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["play_type": 1, "gallery": gallery, "duration": durationSeconds]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Stops slideshow/playlist playback, returning to single-image mode.
    public func stopPlayback(ip: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/stop")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Updates device-level settings. Only non-nil fields are sent, so a
    /// call can touch just the name, just the sleep timers, or all of them.
    public func updateSettings(ip: String, name: String? = nil, sleepDuration: Int? = nil, maxIdle: Int? = nil, idxWakeSens: Int? = nil) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/settings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let sleepDuration { body["sleep_duration"] = sleepDuration }
        if let maxIdle { body["max_idle"] = maxIdle }
        if let idxWakeSens { body["idx_wake_sens"] = idxWakeSens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// The frame's keep-alive: per the API docs, periodic calls stop it
    /// entering idle sleep. There's no "off" call — stopping the calls is
    /// how it's released.
    public func whistle(ip: String) async throws {
        let url = URL(string: try baseURL(ip: ip) + "/whistle")!
        let (_, response) = try await session.data(from: url)
        try checkStatus(response)
    }

    /// Whether `path` (e.g. `/gallerys/Random/foo_P.jpg`) already exists on
    /// the frame — a HEAD request, which the frame answers with 200/404 in
    /// well under a second without transferring the image (checked directly
    /// against the device). Any failure to get a definite answer (timeout,
    /// frame asleep) reports `false`: the caller's fallback is to upload,
    /// which is always safe, just slower.
    public func imageExists(ip: String, path: String) async -> Bool {
        guard let base = try? baseURL(ip: ip), let url = URL(string: base + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    public func fetchImageData(ip: String, path: String) async throws -> Data {
        let url = try URL(string: baseURL(ip: ip) + path)!
        let (data, response) = try await readSession.data(from: url)
        try checkStatus(response)
        return data
    }

    /// Best-effort: creates a gallery if it doesn't already exist. Ignores
    /// failure (e.g. it already exists) since this is purely a convenience
    /// to keep generated content out of the user's own galleries.
    public func ensureGallery(ip: String, name: String) async {
        guard var components = try? URLComponents(string: baseURL(ip: ip) + "/gallery") else { return }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        _ = try? await session.data(for: request)
    }

    private struct UploadResponse: Decodable {
        let path: String
    }

    /// Uploads a JPEG to a gallery and, if `showNow`, displays it immediately.
    /// Returns the stored path on the device (e.g. `/gallerys/{gallery}/{filename}`).
    public func uploadImage(ip: String, filename: String, gallery: String, imageData: Data, showNow: Bool) async throws -> String {
        var components = URLComponents(string: try baseURL(ip: ip) + "/upload")!
        components.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "gallery", value: gallery),
            URLQueryItem(name: "show_now", value: showNow ? "1" : "0")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await uploadSession.data(for: request)
        try checkStatus(response)
        return try JSONDecoder().decode(UploadResponse.self, from: data).path
    }

    /// Uploads several JPEGs in one `POST /image/uploadMulti` request.
    /// Measured against the real frame: 5 x ~1MB took ~21s this way versus
    /// ~73s as five separate `/upload` calls. Returns the filenames the frame
    /// reports as uploaded; throws if the request itself fails.
    public func uploadImages(ip: String, gallery: String, files: [(filename: String, data: Data)]) async throws -> [String] {
        var components = URLComponents(string: try baseURL(ip: ip) + "/image/uploadMulti")!
        components.queryItems = [
            URLQueryItem(name: "gallery", value: gallery),
            URLQueryItem(name: "override", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for file in files {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"images\"; filename=\"\(file.filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(file.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await batchUploadSession.data(for: request)
        try checkStatus(response)
        let decoded = try JSONDecoder().decode(MultiUploadResponse.self, from: data)
        return decoded.files.filter { $0.status == "uploaded" }.map { ($0.path as NSString).lastPathComponent }
    }

    private struct MultiUploadResponse: Decodable {
        struct File: Decodable { let path: String; let status: String }
        let files: [File]
    }

    /// Deletes a single image from a gallery on the device.
    public func deleteImage(ip: String, filename: String, gallery: String) async throws {
        var components = URLComponents(string: try baseURL(ip: ip) + "/image/delete")!
        components.queryItems = [
            URLQueryItem(name: "image", value: filename),
            URLQueryItem(name: "gallery", value: gallery)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Deletes an entire gallery and all its images from the device.
    public func deleteGallery(ip: String, name: String) async throws {
        var components = URLComponents(string: try baseURL(ip: ip) + "/gallery")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// One entry from `/log/list`. The docs
    /// (https://bloomin8.readme.io/reference/get_log-list) claim a bare
    /// array of filename strings, but the device actually returns an array
    /// of objects — confirmed directly against a real frame — same
    /// documented-vs-actual mismatch as `/gallery/list` returning
    /// `GalleryEntry` objects instead of bare strings too.
    public struct LogFileInfo: Decodable, Identifiable, Hashable {
        public let name: String
        public let size: Int?
        public var id: String { name }
    }

    /// Lists the frame's on-device diagnostic log files (e.g.
    /// `2025-12-05.log`) — see `GET /log/list` in the device API docs.
    public func fetchLogList(ip: String) async throws -> [LogFileInfo] {
        let url = try URL(string: baseURL(ip: ip) + "/log/list")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        return try JSONDecoder().decode([LogFileInfo].self, from: data)
    }

    /// Downloads one log file's raw text content — `GET /log/{filename}`
    /// (https://bloomin8.readme.io/reference/get_log-filename).
    public func fetchLogContent(ip: String, filename: String) async throws -> String {
        let url = try URL(string: baseURL(ip: ip) + "/log/\(filename)")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BloominError.badResponse("log file wasn't valid text")
        }
        return text
    }

    // MARK: - System controls

    private func post(ip: String, path: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Puts the frame to sleep now (`POST /sleep`).
    public func sleepNow(ip: String) async throws { try await post(ip: ip, path: "/sleep") }

    /// Restarts the frame (`POST /reboot`).
    public func reboot(ip: String) async throws { try await post(ip: ip, path: "/reboot") }

    /// Clears the screen to solid white (`POST /clearScreen`) — screen
    /// maintenance for e-ink ghosting.
    public func clearScreen(ip: String) async throws { try await post(ip: ip, path: "/clearScreen") }

    public struct TaskState: Decodable {
        public let status: Int?
        public let msg: String?
    }

    /// What the frame's task processor is doing (`GET /state`), e.g. "Ready".
    public func fetchState(ip: String) async throws -> TaskState {
        let url = try URL(string: baseURL(ip: ip) + "/state")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        return try JSONDecoder().decode(TaskState.self, from: data)
    }

    // MARK: - Frame logging

    public struct LogConfig: Decodable, Equatable {
        public let logOn: Bool
        public let logKeepDays: Int
        enum CodingKeys: String, CodingKey {
            case logOn = "log_on"
            case logKeepDays = "log_keep_days"
        }
    }

    public func fetchLogConfig(ip: String) async throws -> LogConfig {
        let url = try URL(string: baseURL(ip: ip) + "/log/config")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        return try JSONDecoder().decode(LogConfig.self, from: data)
    }

    /// `keepDays` 0 keeps logs indefinitely.
    public func updateLogConfig(ip: String, logOn: Bool, keepDays: Int) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/log/config")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["log_on": logOn, "log_keep_days": keepDays])
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Deletes every log file on the frame (`DELETE /log`).
    public func deleteAllLogs(ip: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/log")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    // MARK: - Playlists

    public struct PlaylistSummary: Decodable, Identifiable, Hashable {
        public let name: String
        public let time: Int?
        public var id: String { name }
        public init(name: String, time: Int?) {
            self.name = name
            self.time = time
        }
    }

    public struct PlaylistItem: Hashable {
        public var path: String
        public var durationSeconds: Int
        public init(path: String, durationSeconds: Int) {
            self.path = path
            self.durationSeconds = durationSeconds
        }
    }

    public struct Playlist: Hashable {
        public var name: String
        public var type: String
        public var items: [PlaylistItem]
    }

    private struct PlaylistWire: Decodable {
        let name: String
        let type: String?
        let list: [Item]?
        struct Item: Decodable {
            let name: String
            let duration: Int?
        }
    }

    public func fetchPlaylists(ip: String) async throws -> [PlaylistSummary] {
        let url = try URL(string: baseURL(ip: ip) + "/playlist/list")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response)
        return try JSONDecoder().decode([PlaylistSummary].self, from: data)
    }

    public func fetchPlaylist(ip: String, name: String) async throws -> Playlist {
        var components = URLComponents(string: try baseURL(ip: ip) + "/playlist")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        let (data, response) = try await readSession.data(from: components.url!)
        try checkStatus(response)
        let wire = try JSONDecoder().decode(PlaylistWire.self, from: data)
        return Playlist(
            name: wire.name,
            type: wire.type ?? "duration",
            items: (wire.list ?? []).map { PlaylistItem(path: $0.name, durationSeconds: $0.duration ?? 0) }
        )
    }

    /// Creates or overwrites a "duration" playlist: each image shows for its
    /// own number of seconds, in order (`PUT /playlist`). The "time" type
    /// is left out — the docs don't say what its `time` strings look like.
    public func savePlaylist(ip: String, name: String, items: [PlaylistItem]) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/playlist")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let list: [[String: Any]] = items.map { ["name": $0.path, "duration": $0.durationSeconds] }
        let body: [String: Any] = ["name": name, "type": "duration", "list": list]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await batchUploadSession.data(for: request)
        try checkStatus(response)
    }

    public func deletePlaylist(ip: String, name: String) async throws {
        var components = URLComponents(string: try baseURL(ip: ip) + "/playlist")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    /// Starts playing a playlist on the frame (`POST /show`, play_type 2).
    public func playPlaylist(ip: String, name: String) async throws {
        let url = try URL(string: baseURL(ip: ip) + "/show")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["play_type": 2, "playlist": name])
        let (_, response) = try await session.data(for: request)
        try checkStatus(response)
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BloominError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BloominError.http(http.statusCode)
        }
    }
}
