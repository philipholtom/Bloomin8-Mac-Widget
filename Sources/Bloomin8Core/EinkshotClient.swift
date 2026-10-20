import Foundation

public struct EinkshotDeviceStatus: Decodable {
    public let name: String
    public let remoteImageOn: Bool
    public let remoteImageInterval: String
    public let hasPending: Bool
    public let estimatedPushTime: String?

    enum CodingKeys: String, CodingKey {
        case name
        case remoteImageOn = "remote_image_on"
        case remoteImageInterval = "remote_image_interval"
        case hasPending = "has_pending"
        case estimatedPushTime = "estimated_push_time"
    }
}

public struct EinkshotPushResult: Decodable {
    public let remoteImageId: String
    public let estimatedPushTime: String

    enum CodingKeys: String, CodingKey {
        case remoteImageId = "remote_image_id"
        case estimatedPushTime = "estimated_push_time"
    }
}

public enum EinkshotError: LocalizedError {
    case noToken
    case badResponse(String)
    case http(Int)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .noToken: return "Set a remote push token in Settings first."
        case .badResponse(let detail): return "Unexpected response: \(detail)"
        case .http(let code): return "Remote service returned HTTP \(code)."
        case .api(let message): return message
        }
    }
}

/// Client for the frame's separate cloud relay API ("einkshot") — pushes an
/// image over the internet rather than the local LAN, for when the Mac
/// isn't on the same network as the frame. Kept entirely separate from
/// `BloominClient`: different base URL, bearer-token auth instead of none,
/// and async delivery on the frame's next scheduled wake rather than an
/// immediate response.
public final class EinkshotClient {
    private static let baseURL = "https://einkshot-349134901638.us-central1.run.app/open-api"
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    private func makeRequest(_ path: String, method: String, token: String) throws -> URLRequest {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw EinkshotError.noToken }
        let url = URL(string: Self.baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func fetchStatus(token: String) async throws -> EinkshotDeviceStatus {
        let request = try makeRequest("/device/status", method: "GET", token: token)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        struct Wrapper: Decodable { let device: EinkshotDeviceStatus }
        return try JSONDecoder().decode(Wrapper.self, from: data).device
    }

    public func pushImage(token: String, imageData: Data) async throws -> EinkshotPushResult {
        var request = try makeRequest("/push", method: "POST", token: token)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(EinkshotPushResult.self, from: data)
    }

    /// Returns the cancelled image's ID, or nil if nothing was pending.
    @discardableResult
    public func cancelPending(token: String) async throws -> String? {
        let request = try makeRequest("/push", method: "DELETE", token: token)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        struct Wrapper: Decodable {
            let remoteImageId: String?
            enum CodingKeys: String, CodingKey { case remoteImageId = "remote_image_id" }
        }
        return try JSONDecoder().decode(Wrapper.self, from: data).remoteImageId
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw EinkshotError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let message: String? }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw message.map(EinkshotError.api) ?? EinkshotError.http(http.statusCode)
        }
    }
}
