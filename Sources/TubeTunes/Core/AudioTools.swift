import Foundation

/// ffmpeg-based audio work: previews, waveforms, frames and the final export.
enum AudioTools {
    static let envelopeRate = 20.0   // envelope windows per second
    private static let pcmRate = 8000

    private static func fmt(_ t: Double) -> String { String(format: "%.3f", t) }

    /// AVFoundation can't play WebM/Opus, so the editor plays an AAC copy.
    static func makePreview(source: URL, dest: URL) async throws {
        try await Tools.run("ffmpeg", ["-v", "error", "-y", "-i", source.path, "-vn",
                                       "-c:a", "aac_at", "-b:a", "160k", dest.path])
    }

    /// Loudness (dBFS) per 1/20 s window, cached next to the source.
    static func envelope(source: URL, cache: URL) async throws -> [Float] {
        if let data = try? Data(contentsOf: cache), !data.isEmpty {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let pcm = try await Tools.run("ffmpeg", ["-v", "error", "-i", source.path, "-vn", "-ac", "1",
                                                 "-ar", "\(pcmRate)", "-f", "s16le", "-"])
        let env = await Task.detached { rmsDB(pcm, window: pcmRate / Int(envelopeRate)) }.value
        try? env.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: cache)
        return env
    }

    private static func rmsDB(_ data: Data, window: Int) -> [Float] {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let count = samples.count / window
            var out = [Float](repeating: -90, count: count)
            for w in 0..<count {
                var sum: Float = 0
                let base = w * window
                for i in base..<(base + window) {
                    let v = Float(samples[i]) / 32768
                    sum += v * v
                }
                out[w] = 20 * log10(max(sqrt(sum / Float(window)), 0.00003))
            }
            return out
        }
    }

    static func extractFrame(video: URL, at time: Double, dest: URL, width: Int? = nil) async throws {
        var args = ["-v", "error", "-y", "-ss", fmt(max(0, time)), "-i", video.path, "-frames:v", "1", "-q:v", "2"]
        if let width { args += ["-vf", "scale=\(width):-2"] }
        try await Tools.run("ffmpeg", args + [dest.path])
    }

    static var outputExtension: String { "m4a" }

    /// Cuts one segment out of the source, applies fades and writes a tagged .m4a.
    static func export(_ seg: Segment, source: URL, artwork: URL?, sourceURL: String, dest: URL) async throws {
        var args = ["-v", "error", "-y", "-ss", fmt(seg.start), "-i", source.path]
        if let artwork { args += ["-i", artwork.path] }
        args += ["-t", fmt(seg.duration), "-map", "0:a:0"]
        if artwork != nil { args += ["-map", "1:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"] }

        if Prefs.audioFormat == "alac" {
            args += ["-c:a", "alac", "-sample_fmt", "s16p"]
        } else {
            args += ["-c:a", "aac_at", "-b:a", "\(max(128, min(320, Prefs.aacBitrate)))k"]
        }

        let fadeIn = min(seg.fadeIn, seg.duration / 2)
        let fadeOut = min(seg.fadeOut, seg.duration / 2)
        var filters: [String] = []
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(fmt(fadeIn)):curve=\(Prefs.fadeCurve)") }
        if fadeOut > 0 {
            filters.append("afade=t=out:st=\(fmt(seg.duration - fadeOut)):d=\(fmt(fadeOut)):curve=\(Prefs.fadeCurve)")
        }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }

        var tags: [(String, String)] = [
            ("title", seg.title), ("artist", seg.artist), ("album", seg.album),
            ("album_artist", seg.albumArtist.isEmpty ? seg.artist : seg.albumArtist),
            ("date", seg.year), ("genre", seg.genre), ("comment", sourceURL),
        ]
        if let n = seg.trackNumber {
            tags.append(("track", seg.trackCount.map { "\(n)/\($0)" } ?? "\(n)"))
        }
        for (key, value) in tags where !value.isEmpty { args += ["-metadata", "\(key)=\(value)"] }

        args += ["-movflags", "+faststart", "-f", "ipod", dest.path]
        try await Tools.run("ffmpeg", args)
    }
}
