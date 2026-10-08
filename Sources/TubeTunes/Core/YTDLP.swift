import Foundation

/// The fields of yt-dlp's info JSON that the app uses.
struct VideoInfo {
    let raw: [String: Any]

    init(raw: [String: Any]) { self.raw = raw }

    private func string(_ key: String) -> String? {
        guard let s = raw[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    var id: String { string("id") ?? "" }
    var title: String { string("title") ?? "" }
    var channel: String { string("channel") ?? string("uploader") ?? "" }
    var duration: Double { (raw["duration"] as? NSNumber)?.doubleValue ?? 0 }
    var description: String { string("description") ?? "" }
    var track: String? { string("track") }
    var album: String? { string("album") }
    var acodec: String { string("acodec") ?? "" }
    var abr: Double { (raw["abr"] as? NSNumber)?.doubleValue ?? 0 }

    /// YouTube Music's artist credit, when the video has one.
    var artist: String? {
        if let list = raw["artists"] as? [String], !list.isEmpty { return list.joined(separator: ", ") }
        return string("artist") ?? string("creator")
    }

    var releaseYear: String? {
        if let y = raw["release_year"] as? NSNumber { return y.stringValue }
        if let d = string("release_date"), d.count >= 4 { return String(d.prefix(4)) }
        return nil
    }

    var chapters: [Chapter] {
        guard let list = raw["chapters"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let start = (c["start_time"] as? NSNumber)?.doubleValue,
                  let end = (c["end_time"] as? NSNumber)?.doubleValue else { return nil }
            return Chapter(title: (c["title"] as? String) ?? "", start: start, end: end)
        }
    }
}

struct PlaylistListing {
    struct Entry { let id: String; let title: String }
    let id: String
    let title: String
    let entries: [Entry]
}

enum YTDLP {
    private static var commonArgs: [String] {
        var args = ["--ignore-config", "--no-warnings"]
        let browser = Prefs.cookiesBrowser
        if !browser.isEmpty { args += ["--cookies-from-browser", browser] }
        return args
    }

    static func version() async -> String? {
        guard let data = try? await Tools.run("yt-dlp", ["--version"]) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func playlist(_ url: String) async throws -> PlaylistListing {
        let data = try await Tools.run("yt-dlp", commonArgs + ["--flat-playlist", "-J", url])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.failed("yt-dlp", 0, "Unreadable playlist data")
        }
        let entries = (json["entries"] as? [[String: Any]] ?? []).compactMap { e -> PlaylistListing.Entry? in
            guard let id = e["id"] as? String else { return nil }
            return .init(id: id, title: e["title"] as? String ?? "")
        }
        return PlaylistListing(id: json["id"] as? String ?? "",
                               title: json["title"] as? String ?? "Playlist",
                               entries: entries)
    }

    /// Downloads the best audio stream plus the thumbnail and info JSON into `dir`.
    static func downloadAudio(_ url: String, into dir: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> (VideoInfo, URL) {
        let args = commonArgs + [
            "-f", "bestaudio/best", "--no-playlist",
            "-P", dir.path,
            "-o", "source.%(ext)s",
            "-o", "thumbnail:thumb.%(ext)s",
            "-o", "infojson:info",
            "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--newline", "--progress-template",
            "download:TTPROG %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s",
            url,
        ]
        try await Tools.run("yt-dlp", args, onLine: progressParser(progress))
        let infoURL = dir.appendingPathComponent("info.info.json")
        let data = try Data(contentsOf: infoURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.failed("yt-dlp", 0, "Unreadable video info")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let source = files.first(where: { $0.hasPrefix("source.") && !$0.hasSuffix(".part") }) else {
            throw ToolError.failed("yt-dlp", 0, "Download finished but no audio file was found")
        }
        return (VideoInfo(raw: raw), dir.appendingPathComponent(source))
    }

    /// Downloads the video (≤1080p) so frames can be picked for artwork.
    static func downloadVideo(_ url: String, into dir: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let args = commonArgs + [
            "-f", "bv*[height<=1080][ext=mp4]/bv*[height<=1080]/b[height<=1080]/bv*/b",
            "--no-playlist", "-P", dir.path, "-o", "video.%(ext)s",
            "--newline", "--progress-template",
            "download:TTPROG %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s",
            url,
        ]
        try await Tools.run("yt-dlp", args, onLine: progressParser(progress))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let video = files.first(where: { $0.hasPrefix("video.") && !$0.hasSuffix(".part") }) else {
            throw ToolError.failed("yt-dlp", 0, "Video download finished but no file was found")
        }
        return dir.appendingPathComponent(video)
    }

    private static func progressParser(_ progress: @escaping @Sendable (Double) -> Void) -> @Sendable (String) -> Void {
        { line in
            guard line.hasPrefix("TTPROG ") else { return }
            let parts = line.split(separator: " ")
            guard parts.count == 3, let done = Double(parts[1]), let total = Double(parts[2]), total > 0 else { return }
            progress(min(1, done / total))
        }
    }
}
