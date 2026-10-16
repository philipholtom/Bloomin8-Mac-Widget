import Foundation
import Combine
import Network

/// Serves the museum cards to the CrowPanel e-paper display over the local
/// network, advertised over Bonjour as `_b8cards._tcp` so the CrowPanel can
/// find the Mac without a configured address:
///
/// - `GET /version` → `{"version": N, "image": ..., "gallery": ..., "battery": ...}`
///   — cheap check for whether anything changed, plus what this Mac last saw
///   on the frame (from its own status polls and sends), so the CrowPanel
///   knows what's showing even while the frame's Wi-Fi is asleep
/// - `GET /cards`   → the whole set, `{"version": N, "cards": {path: card},
///   "hiddenGalleries": [...]}` — hidden galleries are every gallery in a
///   password-locked tab, in any frame profile, so the CrowPanel's gallery
///   picker never lists them.
///
/// The CrowPanel keeps its own copy, so it can still label photos while the
/// Mac is asleep. Both the widget and the app start a server; whichever
/// starts first gets the port and the other quietly does without, since both
/// serve the same file.
@MainActor
public final class MuseumCardServer {
    public static let shared = MuseumCardServer()
    public static let port: NWEndpoint.Port = 8738

    private var listener: NWListener?
    private weak var settings: AppSettings?
    private weak var controller: PhotoController?
    /// Every gallery in a password-locked tab, across all frame profiles.
    private var hiddenGalleries: [String] {
        let tabs = settings?.frameProfiles.flatMap(\.tabs) ?? []
        return Array(Set(tabs.filter(\.isLocked).flatMap(\.galleryNames))).sorted()
    }

    private init() {}

    private var syncTimer: Timer?
    private var enabledCancellable: AnyCancellable?

    /// Starts watching the "card server" setting and serves while it's on.
    /// The setting is re-read from the shared defaults every few seconds, so
    /// switching it off in the app also stops the widget's server.
    public func start(settings: AppSettings, controller: PhotoController) {
        self.settings = settings
        self.controller = controller
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in MuseumCardServer.shared.sync() }
        }
        enabledCancellable = settings.$cardServerEnabled.sink { _ in
            // `@Published` publishes before the value lands in the defaults.
            DispatchQueue.main.async { MuseumCardServer.shared.sync() }
        }
        sync()
    }

    private func sync() {
        let defaults = UserDefaults(suiteName: AppSettings.suiteName) ?? .standard
        let enabled = defaults.object(forKey: "cardServerEnabled") as? Bool ?? true
        if enabled, listener == nil {
            listen()
        } else if !enabled, let running = listener {
            running.cancel()
            listener = nil
        }
    }

    private func listen() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: Self.port)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Blooming8", type: "_b8cards._tcp")
            listener.newConnectionHandler = { connection in
                Task { @MainActor in MuseumCardServer.shared.handle(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("MuseumCardServer: listener failed (probably the other Blooming8 product is serving): \(error)")
                    Task { @MainActor in MuseumCardServer.shared.listener = nil }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("MuseumCardServer: couldn't start: \(error)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer.append(data) }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                    self.respond(to: header, on: connection)
                } else if error != nil || isComplete || buffer.count > 16_384 {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// The card set's version mixed with the hidden-gallery list, so the
    /// CrowPanel re-syncs when either changes (e.g. a tab gets locked).
    /// FNV-1a rather than `Hasher`, which is seeded differently per launch.
    private var servedVersion: Int {
        let hiddenKey = hiddenGalleries.joined(separator: "\u{1F}").utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return MuseumCardStore.shared.snapshot.version &+ Int(hiddenKey % 1_000_000)
    }

    private func versionJSON() -> Data {
        var object: [String: Any] = ["version": servedVersion]
        if let path = controller?.currentImagePath { object["image"] = path }
        if let gallery = controller?.currentGalleryOnDevice { object["gallery"] = gallery }
        if let battery = controller?.batteryPercent { object["battery"] = battery }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func respond(to header: String, on connection: NWConnection) {
        let requestLine = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : ""

        let store = MuseumCardStore.shared
        let (status, body): (String, Data)
        switch (method, path) {
        case ("GET", "/version"):
            store.reload()
            status = "200 OK"
            body = versionJSON()
        case ("GET", "/cards"):
            status = "200 OK"
            body = store.exportJSON(hiddenGalleries: hiddenGalleries)
        default:
            status = "404 Not Found"
            body = Data("{\"error\":\"not found\"}".utf8)
        }

        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
