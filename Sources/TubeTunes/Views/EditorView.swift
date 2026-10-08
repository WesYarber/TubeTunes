import SwiftUI

/// Review/edit window for one download: trim, split, fades, tags, artwork.
struct EditorView: View {
    let itemID: UUID
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var player = PreviewPlayer()
    @State private var envelope: [Float] = []
    @State private var envelopeRange: ClosedRange<Float> = -60...0
    @State private var selection: UUID?
    @State private var zoom: Double = 1
    @State private var showDetect = false
    @State private var artworkFor: UUID?
    @State private var message: String?
    @State private var lookingUp = false

    private var item: DownloadItem? { lib.item(itemID) }
    private var segments: [Segment] { item?.segments ?? [] }
    private var selected: Segment? { segments.first { $0.id == selection } }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                header(item)
                Divider()
                timeline(item).frame(height: 150).padding(.horizontal, 12).padding(.vertical, 8)
                transport(item).padding(.horizontal, 12).padding(.bottom, 8)
                Divider()
                HSplitView {
                    trackList.frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                    detail(item).frame(minWidth: 460, maxWidth: .infinity)
                }
                Divider()
                footer(item)
            }
            .navigationTitle(item.title)
            .task(id: item.previewFile) { await load(item) }
            .onChange(of: segments) { _, segs in player.applyFades(segs) }
            .onDisappear { player.stop() }
            .sheet(isPresented: $showDetect) {
                DetectSongsSheet(item: item, envelope: envelope) { ranges, names in
                    replaceSegments(ranges: ranges, names: names)
                }
            }
            .sheet(item: Binding(get: { artworkFor.map(IdentifiedUUID.init) }, set: { artworkFor = $0?.id })) { target in
                ArtworkEditor(itemID: itemID, segmentID: target.id)
                    .environment(lib)
            }
            .alert("TubeTunes", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
        } else {
            ContentUnavailableView("This download no longer exists", systemImage: "questionmark.folder")
        }
    }

    // MARK: - Loading

    private func load(_ item: DownloadItem) async {
        if selection == nil { selection = item.segments.first?.id }
        guard let preview = lib.file(item, item.previewFile) else { return }
        await player.load(preview)
        player.applyFades(item.segments)
        if let source = lib.file(item, item.sourceFile) {
            let cache = lib.folder(for: item.id).appendingPathComponent("envelope.bin")
            let env = (try? await AudioTools.envelope(source: source, cache: cache)) ?? []
            if !env.isEmpty {
                let sorted = env.sorted()
                let floor = sorted[sorted.count / 50] - 6
                envelopeRange = floor...max(floor + 6, sorted[sorted.count * 998 / 1000])
            }
            envelope = env
        }
    }

    // MARK: - Header

    private func header(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            VideoThumb(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.channel)
                    Text("· \(formatTime(item.duration))")
                    if !item.sourceCodec.isEmpty {
                        Text("· source \(item.sourceCodec) \(Int(item.sourceBitrate)) kbps")
                    }
                    if !item.chapters.isEmpty { Text("· \(item.chapters.count) chapters") }
                    if !item.setlist.isEmpty { Text("· set list of \(item.setlist.count)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: item.status)
            Button { NSWorkspace.shared.open(URL(string: item.url)!) } label: { Image(systemName: "play.rectangle") }
                .help("Open on YouTube")
        }
        .padding(12)
    }

    // MARK: - Timeline

    private func timeline(_ item: DownloadItem) -> some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                WaveformTimeline(
                    envelope: envelope,
                    range: envelopeRange,
                    duration: item.duration,
                    segments: segments,
                    chapters: item.chapters,
                    selection: selection,
                    playhead: player.currentTime,
                    onSeek: { player.seek($0) },
                    onSelect: { if let id = $0 { selection = id } },
                    onMoveEdge: moveEdge
                )
                .frame(width: geo.size.width * zoom, height: geo.size.height)
            }
            .overlay {
                if envelope.isEmpty {
                    ProgressView("Reading audio…").controlSize(.small)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func transport(_ item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            Text("\(formatTime(player.currentTime, precise: true)) / \(formatTime(item.duration))")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)

            Divider().frame(height: 18)

            Button("Split at Playhead", systemImage: "scissors") { splitAtPlayhead() }
            Menu {
                Button("Use Chapters (\(item.chapters.count))") { useChapters() }
                    .disabled(item.chapters.isEmpty)
                Button("Detect Songs…") { showDetect = true }
                    .disabled(envelope.isEmpty)
                Button("Single Track (Whole Video)") {
                    replaceSegments(ranges: [0...item.duration], names: [segments.first?.title ?? item.title])
                }
                Divider()
                Button("Number Tracks 1…\(segments.filter(\.included).count)") {
                    mutate { SegmentBuilder.number(&$0) }
                }
            } label: {
                Label("Split", systemImage: "rectangle.split.3x1")
            }
            .fixedSize()

            Spacer()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...40).frame(width: 140)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Track list

    private var trackList: some View {
        List(selection: $selection) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                HStack(spacing: 8) {
                    Toggle("", isOn: segmentBinding(seg.id).included).labelsHidden().toggleStyle(.checkbox)
                    ArtworkImage(url: item.flatMap { lib.file($0, seg.artworkFile) }, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(seg.title)").lineLimit(1)
                            .foregroundStyle(seg.included ? .primary : .secondary)
                        Text("\(formatTime(seg.start)) – \(formatTime(seg.end)) · \(formatTime(seg.duration))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    if seg.musicPersistentID != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In Music")
                    }
                }
                .tag(seg.id)
                .contextMenu {
                    Button("Play") { player.play(from: seg.start, until: seg.end) }
                    Button("Merge with Next") { merge(seg.id) }.disabled(index == segments.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { delete(seg.id) }.disabled(segments.count == 1)
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ item: DownloadItem) -> some View {
        if let seg = selected {
            SegmentDetail(
                segment: segmentBinding(seg.id),
                artworkURL: lib.file(item, seg.artworkFile),
                trackCount: segments.count,
                lookingUp: lookingUp,
                playhead: player.currentTime,
                maxEnd: item.duration,
                onPlay: { from, to in player.play(from: from, until: to) },
                onChooseArtwork: { artworkFor = seg.id },
                onLookup: { lookup(seg) },
                onApplyToAll: { applyToAll(from: seg) },
                onMerge: { merge(seg.id) },
                onDelete: { delete(seg.id) }
            )
            .id(seg.id)
        } else {
            ContentUnavailableView("Select a track", systemImage: "music.note")
        }
    }

    private func footer(_ item: DownloadItem) -> some View {
        let included = segments.filter(\.included)
        let alreadyAdded = segments.contains { $0.musicPersistentID != nil }
        return HStack {
            if let error = item.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).lineLimit(2).font(.callout)
            } else {
                Text("\(included.count) of \(segments.count) tracks will be added")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == .exporting { ProgressView().controlSize(.small) }
            Button(alreadyAdded ? "Update in Music" : "Add to Music") {
                player.pause()
                Task {
                    await engine.exportAndAdd(itemID)
                    if lib.item(itemID)?.status == .added { dismiss() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(included.isEmpty || item.status == .exporting)
            .help(alreadyAdded ? "Re-exports the tracks and replaces the earlier versions in Music" : "")
        }
        .padding(12)
    }

    // MARK: - Editing

    private func mutate(_ change: (inout [Segment]) -> Void) {
        lib.update(itemID) {
            change(&$0.segments)
            $0.segments.sort { $0.start < $1.start }
        }
    }

    private func segmentBinding(_ id: UUID) -> Binding<Segment> {
        Binding(
            get: { lib.item(itemID)?.segments.first { $0.id == id } ?? .placeholder },
            set: { new in mutate { segs in if let i = segs.firstIndex(where: { $0.id == id }) { segs[i] = new } } }
        )
    }

    private func moveEdge(_ id: UUID, _ edge: SegmentEdge, _ time: Double) {
        mutate { segs in
            guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
            let duration = item?.duration ?? 0
            switch edge {
            case .start:
                let lower = i > 0 ? segs[i - 1].end : 0
                segs[i].start = min(max(time, lower), segs[i].end - 1)
            case .end:
                let upper = i < segs.count - 1 ? segs[i + 1].start : duration
                segs[i].end = max(min(time, upper), segs[i].start + 1)
            }
        }
    }

    private func splitAtPlayhead() {
        let t = player.currentTime
        guard let seg = segments.first(where: { $0.start + 1 < t && t < $0.end - 1 }) else {
            message = "Move the playhead inside a track (at least a second from its edges) to split it."
            return
        }
        var second = seg
        second.id = UUID()
        second.start = t
        second.title = "Track \(segments.count + 1)"
        second.fadeIn = Prefs.fadeInSplit
        second.musicPersistentID = nil
        second.addedToMusicAt = nil
        mutate { segs in
            guard let i = segs.firstIndex(where: { $0.id == seg.id }) else { return }
            segs[i].end = t
            segs[i].fadeOut = Prefs.fadeOutSplit
            segs.append(second)
        }
        selection = second.id
    }

    private func merge(_ id: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == id }), i + 1 < segments.count else { return }
        let next = segments[i + 1]
        removeFromMusic([next])
        mutate { segs in
            segs[i].end = next.end
            segs[i].fadeOut = next.fadeOut
            segs.removeAll { $0.id == next.id }
        }
    }

    private func delete(_ id: UUID) {
        guard segments.count > 1 else { return }
        removeFromMusic(segments.filter { $0.id == id })
        mutate { $0.removeAll { $0.id == id } }
        selection = segments.first?.id
    }

    private func useChapters() {
        guard let item else { return }
        let template = segments.first ?? .placeholder
        var album = TrackMeta(title: "", artist: template.artist, album: template.album,
                              albumArtist: template.albumArtist, year: template.year, genre: template.genre)
        if segments.count == 1 && template.album != Prefs.fallbackAlbum {
            // A single-song album match doesn't apply to a multi-song video.
            album.album = Prefs.fallbackAlbum
        }
        var new = SegmentBuilder.fromChapters(item.chapters, album: album, artwork: template.artworkFile)
        if new.isEmpty { return }
        for i in new.indices { new[i].albumArtist = template.albumArtist }
        removeFromMusic(segments)
        lib.update(itemID) { $0.segments = new }
        selection = new.first?.id
    }

    private func replaceSegments(ranges: [ClosedRange<Double>], names: [String]) {
        guard !ranges.isEmpty else { return }
        let template = segments.first ?? .placeholder
        let new = SegmentBuilder.fromRanges(ranges, names: names, template: template)
        removeFromMusic(segments)
        lib.update(itemID) { $0.segments = new }
        selection = new.first?.id
    }

    private func removeFromMusic(_ old: [Segment]) {
        let ids = old.compactMap(\.musicPersistentID)
        guard !ids.isEmpty else { return }
        Task { for pid in ids { await MusicApp.delete(persistentID: pid) } }
    }

    private func applyToAll(from seg: Segment) {
        mutate { segs in
            for i in segs.indices {
                segs[i].artist = seg.artist
                segs[i].album = seg.album
                segs[i].albumArtist = seg.albumArtist
                segs[i].year = seg.year
                segs[i].genre = seg.genre
                segs[i].artworkFile = seg.artworkFile
            }
        }
    }

    private func lookup(_ seg: Segment) {
        lookingUp = true
        Task {
            defer { lookingUp = false }
            guard let c = await MetadataResolver.searchCatalog(title: seg.title, artist: seg.artist,
                                                               duration: seg.duration) else {
                message = "No match for “\(seg.title)” by \(seg.artist) in the Apple Music catalog."
                return
            }
            var meta = TrackMeta(title: seg.title, artist: seg.artist)
            MetadataResolver.apply(c, to: &meta)
            MetadataResolver.finalize(&meta)
            let art = await engine.downloadArtwork(meta.artworkURL, dir: lib.folder(for: itemID))
            let binding = segmentBinding(seg.id)
            var s = binding.wrappedValue
            s.title = meta.title
            s.artist = meta.artist
            s.album = meta.album
            s.albumArtist = meta.albumArtist
            s.trackNumber = meta.trackNumber
            s.trackCount = meta.trackCount
            s.year = meta.year
            s.genre = meta.genre
            s.metadataSource = meta.source
            if let art { s.artworkFile = art }
            binding.wrappedValue = s
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

// MARK: - Segment detail form

struct SegmentDetail: View {
    @Binding var segment: Segment
    let artworkURL: URL?
    let trackCount: Int
    let lookingUp: Bool
    let playhead: Double
    let maxEnd: Double
    var onPlay: (Double, Double?) -> Void
    var onChooseArtwork: () -> Void
    var onLookup: () -> Void
    var onApplyToAll: () -> Void
    var onMerge: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Button(action: onChooseArtwork) {
                        ArtworkImage(url: artworkURL, size: 132)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "photo.badge.plus").padding(5)
                                    .background(.thinMaterial, in: Circle()).padding(6)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Pick a frame from the video or crop a thumbnail")
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $segment.title)
                        TextField("Artist", text: $segment.artist)
                        TextField("Album", text: $segment.album)
                        TextField("Album Artist", text: $segment.albumArtist)
                    }
                }
                HStack {
                    TextField("Track", value: $segment.trackNumber, format: .number).frame(width: 90)
                    TextField("of", value: $segment.trackCount, format: .number).frame(width: 70)
                    TextField("Year", text: $segment.year).frame(width: 110)
                    TextField("Genre", text: $segment.genre)
                }
                HStack {
                    Button(action: onLookup) {
                        Label("Look Up in Apple Music", systemImage: "magnifyingglass")
                    }
                    .disabled(lookingUp)
                    if lookingUp { ProgressView().controlSize(.small) }
                    Spacer()
                    if !segment.metadataSource.isEmpty {
                        Text("From \(segment.metadataSource)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if trackCount > 1 {
                    Button("Use This Artist, Album & Artwork for All Tracks", action: onApplyToAll)
                }
            } header: { Text("Song") }

            Section {
                HStack {
                    TimeField(label: "Start", value: Binding(
                        get: { segment.start },
                        set: { segment.start = min(max(0, $0), segment.end - 1) }))
                    Button("Set to Playhead") { segment.start = min(playhead, segment.end - 1) }
                }
                HStack {
                    TimeField(label: "End", value: Binding(
                        get: { segment.end },
                        set: { segment.end = max(min(maxEnd, $0), segment.start + 1) }))
                    Button("Set to Playhead") { segment.end = max(playhead, segment.start + 1) }
                }
                LabeledContent("Length", value: formatTime(segment.duration, precise: true))
                HStack {
                    Button("Play Track", systemImage: "play.fill") { onPlay(segment.start, segment.end) }
                    Button("Play Start") { onPlay(segment.start, segment.start + 8) }
                    Button("Play Ending") { onPlay(max(segment.start, segment.end - 8), segment.end) }
                }
            } header: {
                Text("Trim")
            } footer: {
                Text("Drag the edges on the waveform, or type times as m:ss.s.").font(.caption)
            }

            Section {
                fadeRow("Fade in", value: $segment.fadeIn)
                fadeRow("Fade out", value: $segment.fadeOut)
                HStack {
                    Button("Use Single-Song Defaults") {
                        segment.fadeIn = Prefs.fadeInSingle; segment.fadeOut = Prefs.fadeOutSingle
                    }
                    Button("Use Split-Track Defaults") {
                        segment.fadeIn = Prefs.fadeInSplit; segment.fadeOut = Prefs.fadeOutSplit
                    }
                }
            } header: { Text("Fades") }

            if trackCount > 1 {
                Section {
                    HStack {
                        Button("Merge with Next Track", action: onMerge)
                        Button("Delete Track", role: .destructive, action: onDelete)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func fadeRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...15, step: 0.1)
            Text(String(format: "%.1f s", value.wrappedValue)).monospacedDigit().frame(width: 50, alignment: .trailing)
            Stepper("", value: value, in: 0...30, step: 0.5).labelsHidden()
        }
    }
}

// MARK: - Song detection

struct DetectSongsSheet: View {
    let item: DownloadItem
    let envelope: [Float]
    var apply: ([ClosedRange<Double>], [String]) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case silence = "Silence between songs", count = "Known number of songs" }

    @State private var mode: Mode = .silence
    @State private var threshold = Prefs.silenceThreshold
    @State private var minSilence = Prefs.minSilence
    @State private var minSong = Prefs.minSong
    @State private var count = 2
    @State private var useSetlistNames = true

    private var ranges: [ClosedRange<Double>] {
        switch mode {
        case .silence:
            SplitDetector.bySilence(envelope, threshold: threshold, minSilence: minSilence, minSong: minSong)
        case .count:
            SplitDetector.byCount(envelope, count: count, minSong: minSong)
        }
    }

    var body: some View {
        let found = ranges
        VStack(alignment: .leading, spacing: 14) {
            Text("Detect Songs").font(.title2.bold())
            Picker("Method", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch mode {
                case .silence:
                    LabeledContent("Silence below") {
                        Slider(value: $threshold, in: -70 ... -15, step: 1)
                        Text("\(Int(threshold)) dB").monospacedDigit().frame(width: 55)
                    }
                    LabeledContent("Lasting at least") {
                        Slider(value: $minSilence, in: 0.3...6, step: 0.1)
                        Text(String(format: "%.1f s", minSilence)).monospacedDigit().frame(width: 55)
                    }
                    Text("Best for albums and studio sets. For live shows with applause, use “Known number of songs”.")
                        .font(.caption).foregroundStyle(.secondary)
                case .count:
                    Stepper("Number of songs: \(count)", value: $count, in: 2...60)
                    Text("Splits at the quietest moments between songs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Shortest song") {
                    Slider(value: $minSong, in: 20...300, step: 5)
                    Text(formatTime(minSong)).monospacedDigit().frame(width: 55)
                }
                if !item.setlist.isEmpty {
                    Toggle("Name tracks from the description's set list (\(item.setlist.count) songs)", isOn: $useSetlistNames)
                }
            }
            .formStyle(.grouped)

            Text("Found \(found.count) track\(found.count == 1 ? "" : "s"): " +
                 found.prefix(12).map { formatTime($0.upperBound - $0.lowerBound) }.joined(separator: ", ") +
                 (found.count > 12 ? "…" : ""))
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace Tracks") {
                    apply(found, useSetlistNames ? item.setlist : [])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(found.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if !item.setlist.isEmpty { mode = .count; count = item.setlist.count }
            else if !item.chapters.isEmpty { count = item.chapters.count }
        }
    }
}
