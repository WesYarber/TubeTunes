import Foundation
import Observation
import UserNotifications

enum LinkParser {
    struct Parsed {
        var videoID: String?
        var listID: String?
    }

    static func parse(_ text: String) -> Parsed? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host?.lowercased(),
              host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var video = query.first { $0.name == "v" }?.value
        let list = query.first { $0.name == "list" }?.value
        let path = url.pathComponents
        if host.hasSuffix("youtu.be"), path.count > 1 { video = path[1] }
        if let i = path.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), i + 1 < path.count {
            video = path[i + 1]
        }
        guard video != nil || list != nil else { return nil }
        return Parsed(videoID: video, listID: list)
    }

    static func videoURL(_ id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }
    static func playlistURL(_ id: String) -> String { "https://www.youtube.com/playlist?list=\(id)" }
}

enum SegmentBuilder {
    static func make(_ meta: TrackMeta, start: Double, end: Double, artwork: String?, split: Bool) -> Segment {
        Segment(start: start, end: end, title: meta.title, artist: meta.artist, album: meta.album,
                albumArtist: meta.albumArtist, trackNumber: meta.trackNumber, trackCount: meta.trackCount,
                year: meta.year, genre: meta.genre,
                fadeIn: split ? Prefs.fadeInSplit : Prefs.fadeInSingle,
                fadeOut: split ? Prefs.fadeOutSplit : Prefs.fadeOutSingle,
                artworkFile: artwork, metadataSource: meta.source)
    }

    /// Album-level info for a multi-song video (concert, full album).
    static func albumMeta(_ info: VideoInfo) async -> TrackMeta {
        let artist = MetadataResolver.videoArtist(info)
        var meta = TrackMeta(title: "", artist: artist, source: "Video title")
        if let name = MetadataResolver.albumName(info) {
            meta.album = name
            if let c = await MetadataResolver.searchAlbum(name, artist: artist) {
                meta.album = c.cleanCollectionName
                meta.albumArtist = c.artistName ?? artist
                if let d = c.releaseDate, d.count >= 4 { meta.year = String(d.prefix(4)) }
                meta.genre = c.primaryGenreName ?? ""
                meta.artworkURL = c.artworkURL
                meta.source = "Apple Music catalog"
            }
        }
        MetadataResolver.finalize(&meta)
        return meta
    }

    static func fromChapters(_ chapters: [Chapter], album: TrackMeta, artwork: String?) -> [Segment] {
        let realAlbum = album.album != Prefs.fallbackAlbum
        var segments = chapters.map { ch -> Segment in
            let parsed = MetadataResolver.chapterTrack(ch.title, videoArtist: album.artist)
            var meta = album
            meta.title = parsed.title
            meta.artist = parsed.artist
            var seg = make(meta, start: ch.start, end: ch.end, artwork: artwork, split: true)
            seg.included = !parsed.skip
            return seg
        }
        if realAlbum { number(&segments) }
        return segments
    }

    static func fromRanges(_ ranges: [ClosedRange<Double>], names: [String], template: Segment) -> [Segment] {
        var segments = ranges.enumerated().map { i, r -> Segment in
            var seg = template
            seg.id = UUID()
            seg.start = r.lowerBound
            seg.end = r.upperBound
            seg.title = i < names.count ? names[i] : "Track \(i + 1)"
            seg.fadeIn = ranges.count > 1 ? Prefs.fadeInSplit : Prefs.fadeInSingle
            seg.fadeOut = ranges.count > 1 ? Prefs.fadeOutSplit : Prefs.fadeOutSingle
            seg.included = true
            seg.musicPersistentID = nil
            seg.addedToMusicAt = nil
            return seg
        }
        if template.album != Prefs.fallbackAlbum && ranges.count > 1 { number(&segments) }
        return segments
    }

    static func number(_ segments: inout [Segment]) {
        let count = segments.filter(\.included).count
        var n = 0
        for i in segments.indices where segments[i].included {
            n += 1
            segments[i].trackNumber = n
            segments[i].trackCount = count
        }
    }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) async {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                              content: content, trigger: nil))
    }
}

/// Runs the download queue and the playlist monitor.
@MainActor @Observable
final class Engine {
    static let shared = Engine()

    var active: Set<UUID> = []
    var syncing: Set<UUID> = []
    var lastSync: Date?

    @ObservationIgnored private let lib = Library.shared
    @ObservationIgnored private var started = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrent = 2

    /// True while the app waits for a background sync to finish before taking over the library.
    var waitingForBackgroundSync = false

    /// App launch: wait for any running background sync to finish, then take over.
    func launch() {
        guard !started else { return }
        started = true
        BackgroundAgent.syncWithPreference()
        Task {
            while !SyncLock.shared.tryAcquire() {
                waitingForBackgroundSync = true
                try? await Task.sleep(for: .seconds(1))
            }
            if waitingForBackgroundSync {
                lib.reload()
                waitingForBackgroundSync = false
            }
            prepare()
            Notifier.requestAuthorization()
            await backfillTrackNumbers()
            pump()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.syncDuePlaylists()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    /// Cleans up after an interrupted run and removed downloads.
    private func prepare() {
        lib.purgeRemovedFiles()
        for item in lib.items where item.status == .added && item.exportedSegments == nil {
            lib.update(item.id) { $0.exportedSegments = $0.segments }
        }
        for item in lib.items {
            switch item.status {
            case .downloading, .processing:
                lib.update(item.id) { $0.status = .queued }
            case .exporting:
                lib.update(item.id) { $0.status = .needsReview }
            default: break
            }
        }
    }

    private func isDue(_ p: Playlist) -> Bool {
        guard p.enabled else { return false }
        guard let last = p.lastChecked else { return true }
        // A minute of slack so a check isn't skipped because the timer fired a little early.
        return Date().timeIntervalSince(last) >= max(5, Prefs.checkIntervalMinutes) * 60 - 60
    }

    /// Cheap test the background agent runs before doing anything (just reads the library).
    var hasBackgroundWork: Bool {
        lib.playlists.contains(where: isDue)
            || lib.items.contains { [.queued, .downloading, .processing].contains($0.status) }
    }

    /// One headless pass: check due playlists, download/add anything new, then return.
    func runBackgroundPass() async {
        prepare()
        await backfillTrackNumbers()
        await syncDuePlaylists()
        pump()
        while !active.isEmpty { try? await Task.sleep(for: .seconds(1)) }
    }

    func syncDuePlaylists() async {
        for p in lib.playlists where isDue(p) { await sync(p.id) }
        lastSync = Date()
    }

    // MARK: - Queue

    @discardableResult
    func addVideo(id videoID: String, title: String = "", playlist: UUID? = nil, autoAdd: Bool) -> UUID {
        let item = DownloadItem(videoID: videoID, url: LinkParser.videoURL(videoID), title: title,
                                playlistID: playlist, autoAdd: autoAdd)
        lib.items.append(item)
        lib.save()
        pump()
        return item.id
    }

    func retry(_ id: UUID) {
        lib.update(id) {
            $0.status = $0.sourceFile == nil || $0.segments.isEmpty ? .queued : .needsReview
            $0.errorMessage = nil
        }
        pump()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// Removes a download. With an undo manager, Edit › Undo puts it back (its files are kept
    /// until the next launch).
    func remove(_ id: UUID, undoManager: UndoManager? = nil) {
        guard let index = lib.items.firstIndex(where: { $0.id == id }) else { return }
        var item = lib.items[index]
        tasks[id]?.cancel()
        lib.removeItem(id)
        guard let undoManager else { return }
        if item.status.isBusy { item.status = item.segments.isEmpty ? .queued : .needsReview }
        undoManager.registerUndo(withTarget: self) { engine in
            MainActor.assumeIsolated {
                engine.lib.items.insert(item, at: min(index, engine.lib.items.count))
                engine.lib.save()
                engine.pump()
                undoManager.registerUndo(withTarget: engine) { e in
                    MainActor.assumeIsolated { e.remove(id, undoManager: undoManager) }
                }
            }
        }
        undoManager.setActionName("Remove Download")
    }

    private func pump() {
        while active.count < maxConcurrent,
              let next = lib.items.first(where: { $0.status == .queued && !active.contains($0.id) }) {
            let id = next.id
            active.insert(id)
            tasks[id] = Task { [weak self] in
                await self?.process(id)
                self?.active.remove(id)
                self?.tasks[id] = nil
                self?.lib.progress[id] = nil
                self?.pump()
            }
        }
    }

    private func process(_ id: UUID) async {
        guard let item = lib.item(id) else { return }
        let dir = lib.folder(for: id)
        do {
            lib.update(id) { $0.status = .downloading; $0.errorMessage = nil }
            let (info, source) = try await YTDLP.downloadAudio(item.url, into: dir) { p in
                Task { @MainActor in Library.shared.progress[id] = p }
            }
            lib.progress[id] = nil
            let hasThumb = FileManager.default.fileExists(atPath: dir.appendingPathComponent("thumb.jpg").path)
            let setlist = MetadataResolver.setlist(from: info.description)
            lib.update(id) {
                $0.status = .processing
                $0.title = info.title
                $0.channel = info.channel
                $0.duration = info.duration
                $0.chapters = info.chapters
                $0.setlist = setlist
                $0.sourceFile = source.lastPathComponent
                $0.thumbnailFile = hasThumb ? "thumb.jpg" : nil
                $0.sourceCodec = info.acodec
                $0.sourceBitrate = info.abr
            }

            try await AudioTools.makePreview(source: source, dest: dir.appendingPathComponent("preview.m4a"))
            lib.update(id) { $0.previewFile = "preview.m4a" }

            var thumbArt: String?
            if hasThumb, (try? ImageTools.writeSquare(from: dir.appendingPathComponent("thumb.jpg"),
                                                      to: dir.appendingPathComponent("art-thumb.jpg"))) != nil {
                thumbArt = "art-thumb.jpg"
            }

            let segments = try await buildSegments(info: info, source: source, dir: dir,
                                                   setlist: setlist, thumbArt: thumbArt)
            lib.update(id) { $0.segments = segments; $0.status = .needsReview }

            NSLog("Processed \(info.title) (\(segments.count) track(s)); auto-add: \(item.autoAdd)")
            if item.autoAdd { await exportAndAdd(id) }
        } catch is CancellationError {
            lib.update(id) { $0.status = .failed; $0.errorMessage = "Cancelled" }
        } catch {
            lib.update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
        }
    }

    private func buildSegments(info: VideoInfo, source: URL, dir: URL, setlist: [String],
                               thumbArt: String?) async throws -> [Segment] {
        let chapters = info.chapters
        let duration = info.duration > 0 ? info.duration : (chapters.last?.end ?? 0)
        let splitChapters = Prefs.autoSplitChapters && chapters.count >= max(2, Prefs.minChaptersToSplit)
        let splitSetlist = Prefs.autoSplitChapters && !splitChapters && setlist.count >= 2
            && duration >= Double(setlist.count) * 60

        guard splitChapters || splitSetlist else {
            let meta = await MetadataResolver.resolveSingle(info)
            let art = await downloadArtwork(meta.artworkURL, dir: dir) ?? thumbArt
            return [SegmentBuilder.make(meta, start: 0, end: duration, artwork: art, split: false)]
        }

        let album = await SegmentBuilder.albumMeta(info)
        let art = await downloadArtwork(album.artworkURL, dir: dir) ?? thumbArt
        if splitChapters {
            return SegmentBuilder.fromChapters(chapters, album: album, artwork: art)
        }
        let env = try await AudioTools.envelope(source: source, cache: dir.appendingPathComponent(AudioTools.envelopeCacheName))
        let ranges = SplitDetector.byCount(env, count: setlist.count, minSong: Prefs.minSong)
        var template = SegmentBuilder.make(album, start: 0, end: 0, artwork: art, split: true)
        template.metadataSource = "Description set list"
        return SegmentBuilder.fromRanges(ranges, names: setlist, template: template)
    }

    func downloadArtwork(_ url: URL?, dir: URL) async -> String? {
        guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        let name = "art-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name))
            return name
        } catch { return nil }
    }

    // MARK: - Music

    /// Exports every included track and adds it to Music, replacing earlier versions and removing
    /// tracks that were deleted, merged away or unchecked in the editor since the last export.
    func exportAndAdd(_ id: UUID) async {
        assignTrackNumbers(id)
        guard let item = lib.item(id), let sourceName = item.sourceFile else { return }
        let dir = lib.folder(for: id)
        let outDir = lib.exportFolder(for: id)
        lib.update(id) { $0.status = .exporting; $0.errorMessage = nil }
        var leftovers = Set(item.musicTrackIDs ?? []).union(item.segments.compactMap(\.musicPersistentID))
        var added: [String] = []
        var addedTitles: [String] = []
        do {
            for seg in item.segments {
                guard seg.included else {
                    if seg.musicPersistentID != nil {
                        updateSegment(id, seg.id) { $0.musicPersistentID = nil; $0.addedToMusicAt = nil }
                    }
                    continue
                }
                let base = "\(seg.artist) - \(seg.title)".components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
                    .joined(separator: "_")
                let dest = outDir.appendingPathComponent("\(String(base.prefix(120))).\(AudioTools.outputExtension)")
                try await AudioTools.export(seg, source: dir.appendingPathComponent(sourceName),
                                            artwork: seg.artworkFile.map { dir.appendingPathComponent($0) },
                                            sourceURL: item.url, dest: dest)
                if let old = seg.musicPersistentID {
                    await MusicApp.delete(persistentID: old)
                    leftovers.remove(old)
                }
                let result = try await MusicApp.add(dest)
                if let location = result.location, location != dest.path {
                    try? FileManager.default.removeItem(at: dest)   // Music made its own copy
                }
                updateSegment(id, seg.id) {
                    $0.musicPersistentID = result.persistentID
                    $0.addedToMusicAt = Date()
                }
                added.append(result.persistentID)
                addedTitles.append(seg.title)
            }
            // Music may hand back an existing track when the same song is added again;
            // never delete something that was just (re)added.
            for pid in leftovers.subtracting(added) { await MusicApp.delete(persistentID: pid) }
            NSLog("Added \(added.count) track(s) from \(item.title) to Music")
            lib.update(id) {
                $0.status = .added
                $0.completed = Date()
                $0.musicTrackIDs = added
                $0.exportedSegments = $0.segments
            }
            if item.autoAdd, !addedTitles.isEmpty {
                await Notifier.post("Added to Music", addedTitles.count == 1
                              ? "\(addedTitles[0]) — \(item.segments.first?.artist ?? "")"
                              : "\(addedTitles.count) tracks from \(item.title)")
            }
        } catch {
            NSLog("Adding \(item.title) to Music failed: \(error.localizedDescription)")
            lib.update(id) {
                $0.status = .needsReview
                $0.errorMessage = error.localizedDescription
                // Remember everything that may still be in Music so the next try cleans it up.
                $0.musicTrackIDs = Array(leftovers.union(added))
            }
        }
    }

    // MARK: - Track numbers

    /// Tracks belong to the same album when album name and album artist match (ignoring case).
    private func albumKey(_ s: Segment) -> String {
        "\(s.album)\u{1}\(s.albumArtist.isEmpty ? s.artist : s.albumArtist)".lowercased()
    }

    /// Highest track number already used in that album by other downloads.
    private func highestTrackNumber(in key: String, excluding itemID: UUID? = nil) -> Int {
        lib.items.filter { $0.id != itemID }
            .flatMap(\.segments)
            .filter { albumKey($0) == key }
            .compactMap(\.trackNumber)
            .max() ?? 0
    }

    /// Gives every included track without a number the next free number in its album, in
    /// timeline order, so a split video's songs play in order and new songs append after them.
    private func assignTrackNumbers(_ id: UUID) {
        guard var segs = lib.item(id)?.segments,
              segs.contains(where: { $0.included && $0.trackNumber == nil }) else { return }
        var next: [String: Int] = [:]
        for i in segs.indices where segs[i].included && segs[i].trackNumber == nil {
            let key = albumKey(segs[i])
            let n = next[key] ?? max(highestTrackNumber(in: key, excluding: id),
                                     segs.filter { albumKey($0) == key }.compactMap(\.trackNumber).max() ?? 0) + 1
            segs[i].trackNumber = n
            next[key] = n + 1
        }
        lib.update(id) { $0.segments = segs }
    }

    /// One-time fix for tracks added before every track got a number: numbers them in the order
    /// they were added and sets the number on the existing Music track (no re-export).
    func backfillTrackNumbers() async {
        let flag = "backfilledTrackNumbers"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        struct Candidate { let itemID: UUID; let segID: UUID; let pid: String; let key: String; let order: (Date, Date, Int) }
        var candidates: [Candidate] = []
        for item in lib.items {
            for (offset, seg) in item.segments.enumerated() where seg.trackNumber == nil {
                guard let pid = seg.musicPersistentID else { continue }
                candidates.append(Candidate(itemID: item.id, segID: seg.id, pid: pid, key: albumKey(seg),
                                            order: (seg.addedToMusicAt ?? item.completed ?? item.created,
                                                    item.created, offset)))
            }
        }
        candidates.sort { $0.order < $1.order }
        var next: [String: Int] = [:]
        for c in candidates {
            let n = next[c.key] ?? highestTrackNumber(in: c.key) + 1
            next[c.key] = n + 1
            updateSegment(c.itemID, c.segID) { $0.trackNumber = n }
            await MusicApp.setTrackNumber(persistentID: c.pid, n)
        }
        if !candidates.isEmpty { NSLog("Numbered \(candidates.count) existing track(s) in Music") }
        UserDefaults.standard.set(true, forKey: flag)
    }

    private func updateSegment(_ id: UUID, _ segID: UUID, _ change: (inout Segment) -> Void) {
        lib.update(id) { item in
            if let i = item.segments.firstIndex(where: { $0.id == segID }) { change(&item.segments[i]) }
        }
    }

    // MARK: - Playlists

    enum AddError: LocalizedError {
        case alreadyMonitored(String)
        var errorDescription: String? {
            switch self { case .alreadyMonitored(let t): "“\(t)” is already being monitored." }
        }
    }

    func addPlaylist(listID: String, downloadExisting: Bool, autoAdd: Bool) async throws {
        let url = LinkParser.playlistURL(listID)
        let listing = try await YTDLP.playlist(url)
        if let existing = lib.playlists.first(where: { $0.youtubeID == listID }) {
            throw AddError.alreadyMonitored(existing.title)
        }
        var playlist = Playlist(url: url, youtubeID: listID, title: listing.title, autoAddToMusic: autoAdd)
        if !downloadExisting {
            playlist.knownVideoIDs = Set(listing.entries.map(\.id))
            playlist.lastChecked = Date()
        }
        lib.playlists.append(playlist)
        lib.save()
        if downloadExisting { apply(listing, to: playlist.id) }
    }

    func syncAllPlaylists() async {
        for p in lib.playlists where p.enabled { await sync(p.id) }
        lastSync = Date()
    }

    func sync(_ playlistID: UUID) async {
        guard let p = lib.playlist(playlistID), !syncing.contains(playlistID) else { return }
        syncing.insert(playlistID)
        defer { syncing.remove(playlistID) }
        do {
            apply(try await YTDLP.playlist(p.url), to: playlistID)
        } catch {
            lib.updatePlaylist(playlistID) { $0.lastError = error.localizedDescription; $0.lastChecked = Date() }
        }
    }

    private func apply(_ listing: PlaylistListing, to playlistID: UUID) {
        guard let p = lib.playlist(playlistID) else { return }
        var seen = p.knownVideoIDs
        for entry in listing.entries where !seen.contains(entry.id) {
            if ["[Private video]", "[Deleted video]"].contains(entry.title) { continue }
            seen.insert(entry.id)
            if lib.hasVideo(entry.id) { continue }
            addVideo(id: entry.id, title: entry.title, playlist: playlistID, autoAdd: p.autoAddToMusic)
        }
        lib.updatePlaylist(playlistID) {
            $0.knownVideoIDs = seen
            $0.title = listing.title.isEmpty ? $0.title : listing.title
            $0.lastChecked = Date()
            $0.lastError = nil
        }
    }
}
