import AdbKit
import Foundation

/// Turns shared text/links into something the TV can open.
enum LinkSender {
    enum Payload: Equatable {
        case youtube(URL)
        case web(URL)
        case text(String)
    }

    /// Picks the first http(s) URL in the shared text, normalising YouTube links.
    static func payload(for input: String) -> Payload {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let match = detector?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard let url = match?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .text(trimmed)
        }
        if let youtube = youtubeWatchURL(url) { return .youtube(youtube) }
        return .web(url)
    }

    /// youtu.be/ID, /shorts/ID, ... → https://www.youtube.com/watch?v=ID (see AdbKit's LinkOpener).
    static func youtubeWatchURL(_ url: URL) -> URL? {
        LinkOpener.youtubeWatchURL(url)
    }

    /// Opens the payload on the TV. Returns a short description, e.g. "Playing in YouTube".
    static func send(_ payload: Payload, via adb: AdbConnection, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        switch payload {
        case .youtube(let url): try await LinkOpener.openYouTube(url, via: adb, progress: progress)
        case .web(let url): try await LinkOpener.openWeb(url, via: adb)
        case .text(let text): try await LinkOpener.type(text, via: adb)
        }
    }

    /// Connects using the saved/last-used/default ports (no scanning).
    static func connect(_ device: SavedDevice, key: AdbKey, timeout: Double = 4) async throws -> AdbConnection {
        var lastError: Error = AdbError.connectionFailed("No port to try")
        for port in device.candidatePorts {
            do {
                return try await AdbConnection.connect(host: device.host, port: port, key: key, approvalTimeout: 30)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Quick reachability check of the device's ADB port.
    static func isReachable(_ device: SavedDevice) async -> Bool {
        let open = (try? await PortScanner.openPorts(host: device.host, ports: device.candidatePorts, timeout: 1.2)) ?? []
        return !open.isEmpty
    }
}
