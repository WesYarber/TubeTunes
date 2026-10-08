import Foundation

/// Finds song boundaries in a loudness envelope (see `AudioTools.envelope`).
enum SplitDetector {
    private static let rate = AudioTools.envelopeRate

    /// Songs separated by stretches quieter than `threshold` dB lasting at least `minSilence` seconds.
    /// Each song ends where its silence starts, and the next begins where the silence ends.
    static func bySilence(_ env: [Float], threshold: Double, minSilence: Double, minSong: Double) -> [ClosedRange<Double>] {
        let total = Double(env.count) / rate
        guard total > 0 else { return [] }
        let minRun = max(1, Int(minSilence * rate))
        var runs: [(Double, Double)] = []
        var i = 0
        while i < env.count {
            guard Double(env[i]) < threshold else { i += 1; continue }
            let s = i
            while i < env.count && Double(env[i]) < threshold { i += 1 }
            if i - s >= minRun { runs.append((Double(s) / rate, Double(i) / rate)) }
        }

        var songs: [ClosedRange<Double>] = []
        var start = 0.0
        var end = total
        for (rs, re) in runs {
            if rs <= 0.5 { start = re; continue }           // leading silence
            if re >= total - 0.5 { end = rs; break }         // trailing silence
            if rs - start >= minSong {
                songs.append(start...rs)
                start = re
            }
        }
        if end - start >= minSong || songs.isEmpty {
            songs.append(start...max(start, end))
        } else if let last = songs.popLast() {
            songs.append(last.lowerBound...end)
        }
        return songs
    }

    /// Splits into exactly `count` songs at the quietest moments (good for live sets with applause).
    static func byCount(_ env: [Float], count: Int, minSong: Double) -> [ClosedRange<Double>] {
        let total = Double(env.count) / rate
        guard count > 1, total > 0 else { return total > 0 ? [0...total] : [] }

        // Smooth over ~2 s so short pauses inside a song don't win.
        let half = Int(rate)
        var prefix = [Double](repeating: 0, count: env.count + 1)
        for (i, v) in env.enumerated() { prefix[i + 1] = prefix[i] + Double(v) }
        let smooth = (0..<env.count).map { i -> Double in
            let a = max(0, i - half), b = min(env.count, i + half + 1)
            return (prefix[b] - prefix[a]) / Double(b - a)
        }
        let order = smooth.indices.sorted { smooth[$0] < smooth[$1] }

        var spacing = min(minSong, total / Double(count) * 0.6)
        var picks: [Int] = []
        while spacing >= 5 {
            picks = []
            for idx in order {
                let t = Double(idx) / rate
                if t < spacing / 2 || total - t < spacing / 2 { continue }
                if picks.allSatisfy({ abs(Double($0 - idx)) / rate >= spacing }) {
                    picks.append(idx)
                    if picks.count == count - 1 { break }
                }
            }
            if picks.count == count - 1 { break }
            spacing /= 2
        }

        let cuts = picks.sorted().map { Double($0) / rate }
        let bounds = [0.0] + cuts + [total]
        return zip(bounds, bounds.dropFirst()).map { $0...$1 }
    }
}
