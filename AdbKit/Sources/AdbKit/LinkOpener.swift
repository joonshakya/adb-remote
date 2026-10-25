import Foundation

/// Opens links on a TV: YouTube links in its YouTube app, others in its browser, plain text typed.
/// Shared by the iOS app, its share extension and the Android app.
public enum LinkOpener {
    /// youtu.be/ID, /shorts/ID, /live/ID, m./music. hosts → https://www.youtube.com/watch?v=ID (keeps t= and list=).
    public static func youtubeWatchURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        var id: String?
        if host == "youtu.be" {
            id = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.first == "watch" {
                id = query.first { $0.name == "v" }?.value
            } else if let first = parts.first, ["shorts", "live", "embed", "v"].contains(first), parts.count > 1 {
                id = parts[1]
            }
        }
        guard let id, !id.isEmpty else { return nil }
        var out = URLComponents(string: "https://www.youtube.com/watch")!
        var items = [URLQueryItem(name: "v", value: id)]
        if let t = query.first(where: { $0.name == "t" || $0.name == "start" })?.value {
            items.append(URLQueryItem(name: "t", value: t))
        }
        if let list = query.first(where: { $0.name == "list" })?.value {
            items.append(URLQueryItem(name: "list", value: list))
        }
        out.queryItems = items
        return out.url
    }

    /// YouTube apps in order of preference, with how to reach them.
    private static let youtubeApps: [(package: String, name: String, needsWarmStart: Bool)] = [
        ("com.google.android.youtube.tv", "YouTube", false),
        ("io.gh.reisxd.tizentube.cobalt", "TizenTube", true),
        ("com.liskovsoft.smarttubetv.beta", "SmartTube", false),
        ("com.liskovsoft.smarttubetv", "SmartTube", false),
        ("com.teamsmart.videomanager.tv", "SmartTube", false),
        ("com.google.android.youtube", "YouTube", false),
        ("com.vanced.android.youtube", "YouTube Vanced", false),
    ]

    /// Plays a YouTube watch URL in the TV's YouTube app. Returns e.g. "Playing in YouTube".
    public static func openYouTube(_ url: URL, via adb: AdbConnection, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        let installed = Set(try await adb.shell("pm list packages").output
            .split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) })
        guard let app = youtubeApps.first(where: { installed.contains($0.package) }) else {
            try await view(url, package: nil, adb: adb)
            return "Opened in the TV's browser (no YouTube app found)"
        }
        if app.needsWarmStart {
            // TizenTube ignores links while starting from scratch: start it, wait, then send.
            let running = !(try await adb.shell("pidof \(app.package)").output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !running {
                progress("Starting \(app.name)…")
                try await adb.run("monkey -p \(app.package) -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1 || monkey -p \(app.package) 1")
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        try await view(url, package: app.package, adb: adb)
        return "Playing in \(app.name)"
    }

    /// Opens a web link in the TV's browser.
    public static func openWeb(_ url: URL, via adb: AdbConnection) async throws -> String {
        try await view(url, package: nil, adb: adb)
        return "Opened on the TV"
    }

    /// Types text into whatever field is focused on the TV (ASCII only: `input text`).
    public static func type(_ text: String, via adb: AdbConnection) async throws -> String {
        let ascii = String(text.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map(Character.init))
        guard !ascii.isEmpty else { throw AdbError.command("Only links and English text can be sent this way.") }
        try await adb.run("input text \(shellQuote(ascii.replacingOccurrences(of: " ", with: "%s")))")
        return "Typed on the TV"
    }

    private static func view(_ url: URL, package: String?, adb: AdbConnection) async throws {
        // A bare package name as the last argument restricts the intent to that app (works on Android 4.4+).
        var command = "am start -a android.intent.action.VIEW -d \(shellQuote(url.absoluteString))"
        if let package { command += " \(package)" }
        let output = try await adb.shell(command).output
        if output.contains("Error") {
            throw AdbError.command("The TV couldn't open this link: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
