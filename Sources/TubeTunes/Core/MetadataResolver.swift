import Foundation

struct TrackMeta {
    var title: String
    var artist: String
    var album = ""
    var albumArtist = ""
    var trackNumber: Int?
    var trackCount: Int?
    var year = ""
    var genre = ""
    var artworkURL: URL?
    var source = ""
}

/// One result from the public iTunes Search API (the Apple Music catalog).
struct CatalogResult: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let collectionArtistName: String?
    let trackNumber: Int?
    let trackCount: Int?
    let releaseDate: String?
    let primaryGenreName: String?
    let artworkUrl100: String?
    let trackTimeMillis: Int?

    var artworkURL: URL? {
        artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) }
    }
    var isSingleOrEP: Bool {
        let c = collectionName ?? ""
        return c.hasSuffix(" - Single") || c.hasSuffix(" - EP")
    }
    var cleanCollectionName: String {
        var c = collectionName ?? ""
        for suffix in [" - Single", " - EP"] where c.hasSuffix(suffix) { c.removeLast(suffix.count) }
        return c
    }
}

private struct CatalogResponse: Decodable { let results: [CatalogResult] }

/// What could be worked out from a video title alone.
struct ParsedTitle {
    var title: String
    var artist: String
    var originalArtist: String?
    var isCover = false
    var isLive = false
}

enum MetadataResolver {
    // MARK: - Patterns

    private static let junk = #"\b(official|video|audio|lyrics?|visuali[sz]er|remaster(ed)?|hd|hq|4k|8k|uhd|mv|m/v|clip|oficial|explicit|color coded|full song|not ai|out now|premiere)\b"#
    private static let albumWords = #"\b(full\s+album|full\s+ep|full\s+lp|album\s+completo|complete\s+album)\b"#
    private static let liveWords = #"\b(live|concert|tiny desk|sessions?|unplugged|in studio|festival|performance)\b"#
    private static let coverWords = #"\b(cover(ed)?|tribute|rendition)\b"#
    private static let descriptorWords: Set<String> = [
        "solo", "guitar", "piano", "acoustic", "live", "cover", "instrumental", "fingerstyle", "bass",
        "drum", "drums", "ukulele", "violin", "cello", "sax", "saxophone", "jazz", "orchestra", "orchestral",
        "version", "arrangement", "remix", "session", "performance", "trio", "quartet", "band", "duet",
        "improv", "improvisation", "lesson", "tutorial", "a", "cappella", "acapella", "unplugged",
    ]
    private static let skipChapter = #"^(intro(duction)?|outro|credits|applause|banter|talking|speech|end\s*(card|screen)?|opening|ending|crowd|tuning)$"#

    // MARK: - Text helpers

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func replace(_ s: String, _ pattern: String, with: String = "") -> String {
        s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
    }

    private static func groups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    static func tidy(_ s: String) -> String {
        replace(s, #"\s+"#, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:~,·").union(.whitespacesAndNewlines))
    }

    static func stripQuotes(_ s: String) -> String {
        tidy(s).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’「」"))
    }

    /// Lowercased letters and digits only, without bracketed parts or "feat." credits.
    static func norm(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        t = replace(t, #"[\(\[\{].*?[\)\]\}]"#)
        t = replace(t, #"\b(feat\.?|ft\.?|featuring)\b.*$"#)
        return t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Lead artist without featured guests ("A feat. B" → "A", "A, B" → "A").
    static func mainArtist(_ s: String) -> String {
        let parts = s.components(separatedBy: ",")
        return tidy(replace(parts[0], #"\s+(feat\.?|ft\.?|featuring|with|x)\s+.*$"#))
    }

    /// Looser first-name split, only used for catalog matching.
    private static func firstArtist(_ s: String) -> String {
        tidy(replace(mainArtist(s), #"\s+(&|and)\s+.*$"#))
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        let na = norm(a), nb = norm(b)
        guard na.count >= 3, nb.count >= 3 else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    static func cleanChannel(_ channel: String) -> String {
        var c = replace(channel, #"\s*-\s*topic$"#)
        if c.hasSuffix("VEVO"), c.count > 4 {
            c.removeLast(4)
            c = replace(c, #"([a-z])([A-Z])"#, with: "$1 $2")
        }
        c = replace(c, #"\s+(official|officiel)(\s+channel)?$"#)
        return tidy(c)
    }

    /// Removes "(Official Video)", "[4K]", hashtags and similar noise.
    static func stripJunk(_ s: String, extra: String? = nil) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: #"\s*[\(\[\{【]([^\)\]\}】]*)[\)\]\}】]"#) {
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let whole = Range(m.range, in: out), let inner = Range(m.range(at: 1), in: out) else { continue }
                let text = String(out[inner])
                if matches(text, junk) || (extra.map { matches(text, $0) } ?? false) {
                    out.removeSubrange(whole)
                }
            }
        }
        // "Song | Official Video" and similar pipe-separated noise
        let pipeParts = out.components(separatedBy: " | ").filter { !matches($0, junk) }
        out = pipeParts.joined(separator: " - ")
        out = replace(out, #"\s*[-–—]?\s*official\s+(music\s+)?(video|audio|lyric video)\s*$"#)
        out = replace(out, #"\s#[\p{L}\p{N}_]+"#)
        if let extra { out = replace(out, extra) }
        return tidy(out)
    }

    private static func split(_ s: String) -> (String, String)? {
        for sep in [" - ", " – ", " — ", " -- ", " ~ "] {
            guard let r = s.range(of: sep) else { continue }
            let a = tidy(String(s[..<r.lowerBound])), b = tidy(String(s[r.upperBound...]))
            if !a.isEmpty && !b.isEmpty { return (a, b) }
        }
        return nil
    }

    private static func isDescriptor(_ s: String) -> Bool {
        let words = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy(descriptorWords.contains)
    }

    // MARK: - Title parsing

    static func parseTitle(_ rawTitle: String, channel rawChannel: String) -> ParsedTitle {
        let channel = cleanChannel(rawChannel)
        var s = stripJunk(rawTitle)
        var performer: String?
        let isLive = matches(rawTitle, liveWords) || matches(s, #"\s(at|@)\s"#)

        // "Song - Cover by Someone: Venue"
        if let g = groups(s, #"\b(?:cover(?:ed)?\s+by|performed\s+by)\s+([^:|\(\)\[\]]+?)\s*(?=$|:|\||\(|\[|\s[-–—]\s)"#),
           let r = s.range(of: g[0]) {
            performer = tidy(g[1])
            s = tidy(String(s[..<r.lowerBound]))
        }

        // "(Performer)" or "(Performer Guitar Cover)"
        if let re = try? NSRegularExpression(pattern: #"\s*[\(\[]([^\)\]]+)[\)\]]"#) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
                let text = String(s[inner])
                if matches(text, coverWords) {
                    let name = tidy(replace(text, #"\b(cover(ed)?|tribute|rendition|version|by)\b"#))
                    if performer == nil, !name.isEmpty { performer = name }
                    if performer == nil { performer = channel }
                    s.removeSubrange(whole)
                } else if performer == nil, sameName(text, channel) {
                    performer = tidy(text)
                    s.removeSubrange(whole)
                }
            }
            s = tidy(s)
        }

        // "Performer plays "Song""
        if let g = groups(s, #"^(.+?)\s+(?:plays|performs|sings|covers)\s+["“'‘](.+?)["”'’]"#) {
            return ParsedTitle(title: stripQuotes(g[2]), artist: tidy(g[1]), isCover: true, isLive: isLive)
        }

        if let (a, b) = split(s) {
            if isDescriptor(b) {
                return ParsedTitle(title: stripQuotes(a), artist: performer ?? channel,
                                   isCover: performer != nil, isLive: isLive)
            }
            if let performer {
                // Covers are almost always titled "Song - Original Artist (Performer)".
                return ParsedTitle(title: stripQuotes(a), artist: performer, originalArtist: b,
                                   isCover: true, isLive: isLive)
            }
            var artist = a, title = b
            if sameName(b, channel) && !sameName(a, channel) { (artist, title) = (b, a) }
            // "NORD LIVE: MonoNeon - Stereo"
            if let colon = artist.range(of: ":", options: .backwards) {
                let after = tidy(String(artist[colon.upperBound...]))
                if !after.isEmpty { artist = after }
            }
            return ParsedTitle(title: stripQuotes(title), artist: artist, isLive: isLive)
        }

        if let g = groups(s, #"^(.+?)\s+["“](.+?)["”]\s*$"#) {
            return ParsedTitle(title: stripQuotes(g[2]), artist: performer ?? tidy(g[1]),
                               isCover: performer != nil, isLive: isLive)
        }
        if let g = groups(s, #"^(.+?)\s+(?:live\s+)?(?:at|@)\s+(.+)$"#) {
            return ParsedTitle(title: stripQuotes(s), artist: performer ?? tidy(g[1]),
                               isCover: performer != nil, isLive: true)
        }
        if let g = groups(s, #"^([^:]{2,40}):\s+(.+)$"#) {
            return ParsedTitle(title: stripQuotes(g[2]), artist: performer ?? tidy(g[1]),
                               isCover: performer != nil, isLive: isLive)
        }
        return ParsedTitle(title: stripQuotes(s), artist: performer ?? channel,
                           isCover: performer != nil, isLive: isLive)
    }

    // MARK: - Single songs

    static func resolveSingle(_ info: VideoInfo) async -> TrackMeta {
        var meta: TrackMeta
        if let track = info.track, let artist = info.artist {
            // YouTube Music provides real credits for "Topic" uploads and many official videos.
            meta = TrackMeta(title: track, artist: artist, album: info.album ?? "",
                             year: info.releaseYear ?? "", source: "YouTube Music")
            if let c = await searchCatalog(title: track, artist: artist, duration: info.duration) {
                if meta.album.isEmpty || norm(c.cleanCollectionName) == norm(meta.album) {
                    apply(c, to: &meta, keepNames: true)
                }
            }
        } else {
            let parsed = parseTitle(info.title, channel: info.channel)
            meta = TrackMeta(title: parsed.title, artist: parsed.artist, source: "Video title")
            if parsed.isCover, let original = parsed.originalArtist {
                // Make sure "Song - Artist" wasn't really "Artist - Song".
                let asIs = await searchCatalog(title: parsed.title, artist: original)
                if asIs == nil, await searchCatalog(title: original, artist: parsed.title) != nil {
                    meta.title = original
                }
            } else if !parsed.isCover && !parsed.isLive {
                if let c = await searchCatalog(title: meta.title, artist: meta.artist, duration: info.duration) {
                    apply(c, to: &meta)
                } else if let c = await searchCatalog(title: meta.artist, artist: meta.title, duration: info.duration) {
                    apply(c, to: &meta)
                }
            }
        }
        finalize(&meta)
        return meta
    }

    static func apply(_ c: CatalogResult, to meta: inout TrackMeta, keepNames: Bool = false) {
        if !keepNames {
            meta.title = c.trackName ?? meta.title
            meta.artist = c.artistName ?? meta.artist
        }
        if c.isSingleOrEP && !Prefs.singlesAsAlbums {
            meta.album = ""
        } else {
            meta.album = c.cleanCollectionName
            meta.albumArtist = c.collectionArtistName ?? c.artistName ?? meta.artist
            meta.trackNumber = c.trackNumber
            meta.trackCount = c.trackCount
            meta.artworkURL = c.artworkURL
        }
        if let date = c.releaseDate, date.count >= 4 { meta.year = String(date.prefix(4)) }
        meta.genre = c.primaryGenreName ?? meta.genre
        meta.source = "Apple Music catalog"
    }

    /// Anything not from a real album goes into the "Youtube" album for that artist.
    static func finalize(_ meta: inout TrackMeta) {
        if meta.album.isEmpty {
            meta.album = Prefs.fallbackAlbum
            meta.albumArtist = mainArtist(meta.artist)
            meta.trackNumber = nil
            meta.trackCount = nil
        }
        if meta.albumArtist.isEmpty { meta.albumArtist = mainArtist(meta.artist) }
    }

    // MARK: - Multi-song videos

    static func videoArtist(_ info: VideoInfo) -> String {
        let title = stripJunk(info.title, extra: albumWords)
        let parsed: String
        if albumName(info) != nil, let (a, _) = split(title) {
            parsed = a
        } else {
            parsed = parseTitle(title, channel: info.channel).artist
        }
        // YouTube's credits sometimes list the channel too ("NPR Music, Vince Gill");
        // prefer the name from the title when it's one of the credited artists.
        guard let credited = info.artist else { return parsed }
        let parts = credited.components(separatedBy: ", ")
        return parts.contains { sameName($0, parsed) } ? parsed : credited
    }

    /// The album name for "Artist - Album (Full Album)" uploads.
    static func albumName(_ info: VideoInfo) -> String? {
        guard matches(info.title, albumWords) else { return nil }
        let title = stripJunk(info.title, extra: albumWords)
        if let (_, b) = split(title) { return stripQuotes(b) }
        return title.isEmpty ? nil : stripQuotes(title)
    }

    static func chapterTrack(_ raw: String, videoArtist: String) -> (title: String, artist: String, skip: Bool) {
        var s = replace(raw, #"^\s*\(?\d{1,2}:\d{2}(:\d{2})?\)?\s*[-–—:|]?\s*"#)
        s = replace(s, #"^\s*\d{1,2}\s*[\.\):\-–]\s+"#)
        s = stripJunk(s)
        var title = s, artist = videoArtist
        if let (a, b) = split(s) {
            if sameName(a, videoArtist) { title = b } else if sameName(b, videoArtist) { title = a }
            else if !videoArtist.isEmpty { title = s } else { (artist, title) = (a, b) }
        }
        title = stripQuotes(title)
        return (title.isEmpty ? raw : title, artist, matches(title, skipChapter))
    }

    /// Song names listed under a "SET LIST" / "Tracklist" heading in the description.
    static func setlist(from description: String) -> [String] {
        let lines = description.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            matches($0.trimmingCharacters(in: .whitespaces), #"^(set\s*list|track\s*list|tracklist|songs|song\s*list|program(me)?)\s*:?\s*$"#)
        }) else { return [] }
        var songs: [String] = []
        for line in lines[(start + 1)...] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if songs.isEmpty { continue } else { break } }
            t = replace(t, #"^\s*\(?\d{1,2}:\d{2}(:\d{2})?\)?\s*[-–—:|]?\s*"#)
            t = replace(t, #"^\s*\d{1,2}\s*[\.\):\-–]\s+"#)
            t = stripQuotes(t)
            if !t.isEmpty { songs.append(t) }
            if songs.count >= 60 { break }
        }
        return songs
    }

    // MARK: - Apple Music catalog

    private static func variantFlags(_ s: String) -> Set<String> {
        let words = ["live", "remix", "acoustic", "instrumental", "karaoke", "demo", "cover", "unplugged",
                     "orchestral", "sped up", "slowed", "reprise"]
        return Set(words.filter { matches(s, "\\b\($0)\\b") })
    }

    private static func query(_ params: [String: String], path: String = "search") async -> [CatalogResult] {
        guard Prefs.catalogLookup, var comps = URLComponents(string: "https://itunes.apple.com/\(path)") else { return [] }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "country", value: Prefs.catalogCountry)]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(CatalogResponse.self, from: data) else { return [] }
        return response.results
    }

    static func searchCatalog(title: String, artist: String, duration: Double? = nil) async -> CatalogResult? {
        let wantTitle = norm(title), wantArtist = norm(firstArtist(artist))
        guard !wantTitle.isEmpty, !wantArtist.isEmpty else { return nil }
        let results = await query(["term": "\(firstArtist(artist)) \(replace(title, #"[\(\[].*?[\)\]]"#))",
                                   "entity": "song", "media": "music", "limit": "25"])
        let wantFlags = variantFlags(title)
        var best: (CatalogResult, Int)?
        for r in results {
            guard let name = r.trackName, let by = r.artistName, norm(name) == wantTitle else { continue }
            let nb = norm(by)
            guard nb.contains(wantArtist) || wantArtist.contains(nb) else { continue }
            guard variantFlags(name + " " + (r.collectionName ?? "")) == wantFlags else { continue }
            var score = 0
            if let duration, duration > 0, let ms = r.trackTimeMillis {
                let diff = abs(Double(ms) / 1000 - duration)
                score += diff < 4 ? 4 : diff < 12 ? 2 : diff > 40 ? -2 : 0
            }
            if !r.isSingleOrEP { score += 2 }
            if matches(r.collectionName ?? "", #"karaoke|tribute|made famous|workout|party hits|now that's"#) { score -= 6 }
            if r.collectionArtistName == "Various Artists" { score -= 2 }
            if best == nil || score > best!.1 { best = (r, score) }
        }
        return best?.0
    }

    static func searchAlbum(_ name: String, artist: String) async -> CatalogResult? {
        let results = await query(["term": "\(firstArtist(artist)) \(name)", "entity": "album",
                                   "media": "music", "limit": "15"])
        return results.first {
            norm($0.cleanCollectionName) == norm(name) && sameName($0.artistName ?? "", firstArtist(artist))
        }
    }
}
