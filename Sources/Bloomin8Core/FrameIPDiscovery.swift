import Foundation
import os

/// Finds a frame's IP address on the local network by name, once BLE has
/// confirmed it's awake: sweeps a set of candidate /24 subnets, asking each
/// host's `/deviceInfo` for its name, and returns the IP whose name matches.
///
/// There's no way to learn the IP over BLE itself (the frame's GATT services
/// don't expose it — see `BLEWaker`), so this is a local-network scan, not a
/// Bluetooth one. It only works once the frame is actually reachable over IP,
/// which is why callers should send a `BLEWaker` wake pulse first.
public enum FrameIPDiscovery {
    // Only called from ConnectCanvasView (Bloomin8App) today, not the
    // widget, so this logs under the app's subsystem — matching where
    // `log stream --predicate 'subsystem == "..."'` would actually be
    // pointed to watch a connect attempt happen.
    private static let log = Logger(subsystem: "com.pholtom.blooming8app", category: "ip-discovery")

    /// Home mesh routers commonly split IoT/guest devices onto a separate,
    /// sequentially-numbered subnet (e.g. this Mac on 192.168.0.x, a frame on
    /// 192.168.3.x) rather than the Mac's own /24 — routed, so reachable, but
    /// invisible to ARP and not something the Mac's own address reveals. So
    /// this tries the Mac's own subnet first, then nearby third-octet values
    /// (closest first), rather than just the one /24 it happens to be on.
    private static let thirdOctetSearchRadius = 6

    /// Overall wall-clock budget for the whole multi-subnet sweep. Without
    /// this, a network where nothing ever answers (wrong name, frame still
    /// asleep, etc.) would take searchRadius*2+1 subnets × up to 254 hosts ×
    /// timeoutPerHost to give up — several minutes. This bounds it to
    /// something a person will actually wait out.
    private static let overallTimeout: TimeInterval = 45

    public static func findIP(matchingName targetName: String, timeoutPerHost: TimeInterval = 0.9, maxConcurrent: Int = 32) async -> String? {
        await withTaskGroup(of: String??.self) { group in
            group.addTask {
                await performScan(matchingName: targetName, timeoutPerHost: timeoutPerHost, maxConcurrent: maxConcurrent)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
                log.error("discover: overall \(overallTimeout)s budget exceeded, giving up")
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    private static func performScan(matchingName targetName: String, timeoutPerHost: TimeInterval, maxConcurrent: Int) async -> String? {
        guard let selfIP = localIPv4() else {
            log.error("discover: no local IPv4 found, aborting")
            return nil
        }
        let target = targetName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        let bases = candidateSubnetBases(of: selfIP)
        log.notice("discover: start target='\(target, privacy: .public)' selfIP=\(selfIP, privacy: .public) subnets=\(bases.joined(separator: ","), privacy: .public)")
        let started = Date()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutPerHost
        config.timeoutIntervalForResource = timeoutPerHost
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        for base in bases {
            let candidates = (1...254).map { "\(base).\($0)" }.filter { $0 != selfIP }
            var index = 0
            var namesSeenThisSubnet = 0

            while index < candidates.count {
                let chunk = candidates[index..<min(index + maxConcurrent, candidates.count)]
                let found = await withTaskGroup(of: (String, String?, Error?)?.self, returning: String?.self) { group in
                    for ip in chunk {
                        group.addTask {
                            guard let url = URL(string: "http://\(ip)/deviceInfo") else { return nil }
                            do {
                                let (data, response) = try await session.data(from: url)
                                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                                    return (ip, nil, nil)
                                }
                                guard let info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else {
                                    return (ip, nil, nil)
                                }
                                return (ip, info.name, nil)
                            } catch {
                                return (ip, nil, error)
                            }
                        }
                    }
                    var matchedIP: String?
                    for await result in group {
                        guard let (ip, name, error) = result else { continue }
                        if let name {
                            namesSeenThisSubnet += 1
                            log.debug("discover: \(ip, privacy: .public) answered name='\(name, privacy: .public)'")
                            if name.caseInsensitiveCompare(target) == .orderedSame {
                                log.notice("discover: MATCH \(ip, privacy: .public) after \(Date().timeIntervalSince(started))s")
                                matchedIP = ip
                                group.cancelAll()
                            }
                        } else if let error {
                            let nsError = error as NSError
                            // Only log the interesting failure modes, not the
                            // expected flood of "connection refused"/"no
                            // route" from the hundreds of addresses with
                            // nothing listening.
                            if nsError.code == NSURLErrorTimedOut {
                                log.debug("discover: \(ip, privacy: .public) timed out")
                            }
                        }
                    }
                    return matchedIP
                }
                if let found { return found }
                index += maxConcurrent
            }
            log.notice("discover: subnet \(base, privacy: .public) exhausted, \(namesSeenThisSubnet) device(s) answered, no match")
        }
        log.error("discover: exhausted \(bases.count) subnets after \(Date().timeIntervalSince(started))s, no match for '\(target, privacy: .public)'")
        return nil
    }

    /// Subnet bases to try, in priority order: the Mac's own subnet, then
    /// third-octet neighbors expanding outward (own+1, own-1, own+2, ...),
    /// clamped to 0...255 and capped by `thirdOctetSearchRadius`.
    private static func candidateSubnetBases(of ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let ownThird = Int(parts[2]) else { return [] }
        let firstTwo = parts[0...1].joined(separator: ".")

        var thirds = [ownThird]
        for delta in 1...thirdOctetSearchRadius {
            if ownThird + delta <= 255 { thirds.append(ownThird + delta) }
            if ownThird - delta >= 0 { thirds.append(ownThird - delta) }
        }
        return thirds.map { "\(firstTwo).\($0)" }
    }

    /// This Mac's own IPv4 address on its active Wi-Fi/Ethernet interface,
    /// via `getifaddrs` — skips loopback and any interface that isn't up.
    private static func localIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var result: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sockLen = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, sockLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: host)
            // Prefer en0 (typically Wi-Fi on Mac laptops); fall back to
            // whatever else turns up if it's not present.
            let ifName = String(cString: ptr.pointee.ifa_name)
            if ifName == "en0" { return name }
            result = result ?? name
        }
        return result
    }
}
