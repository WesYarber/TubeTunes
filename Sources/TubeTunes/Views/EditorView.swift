import SwiftUI

/// Review/edit window for one download: trim, split, fades, tags, artwork.
struct EditorView: View {
    let itemID: UUID
    /// Returns to the list.
    var onClose: () -> Void
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.undoManager) private var undoManager

    @State private var player = PreviewPlayer()
    @State private var draft: EditorDraft
    @State private var showLeavePrompt = false
    @State private var envelope: [Float] = []
    @State private var envelopeRange: ClosedRange<Float> = -60...0
    @State private var selection: UUID?
    @State private var zoom: Double = 1
    @State private var viewStart: Double = 0
    @State private var overviewDragStart: Double?
    /// Like Logic's Catch: the view follows the playhead until you scroll away.
    @State private var followPlayhead = true
    @State private var showDetect = false
    @State private var artworkFor: UUID?
    @State private var message: String?
    @State private var lookingUp = false

    init(itemID: UUID, onClose: @escaping () -> Void) {
        self.itemID = itemID
        self.onClose = onClose
        _draft = State(initialValue: EditorDraft(itemID: itemID))
    }

    private var item: DownloadItem? { lib.item(itemID) }
    private var segments: [Segment] { draft.segments }
    private var selected: Segment? { segments.first { $0.id == selection } }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                header(item)
                Divider()
                VStack(spacing: 4) {
                    timeline(item).frame(height: 150)
                    overview(item)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                transport(item).padding(.horizontal, 12).padding(.bottom, 8)
                Divider()
                HSplitView {
                    trackList.frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
                    detail(item).frame(minWidth: 460, maxWidth: .infinity)
                }
                Divider()
                footer(item)
            }
            .background(SpacebarCatcher { togglePlay() })
            .navigationTitle(item.title)
            .task(id: item.previewFile) { await load(item) }
            .toolbar { toolbar(item, dirty: draft.isDirty) }
            .confirmationDialog("Save your changes to “\(item.title)”?", isPresented: $showLeavePrompt) {
                Button("Save") { draft.save(); leave() }
                Button("Don't Save", role: .destructive) { leave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saved changes stay in TubeTunes until you click Update in Music.")
            }
            .onAppear { draft.undoManager = undoManager }
            .onChange(of: undoManager) { _, um in draft.undoManager = um }
            .onChange(of: segments) { _, segs in player.applyFades(segs) }
            .onChange(of: player.currentTime) { _, t in follow(t) }
            .onDisappear {
                player.stop()
                draft.detach()
            }
            .sheet(isPresented: $showDetect) {
                DetectSongsSheet(item: item, envelope: envelope) { ranges, names in
                    replaceSegments(ranges: ranges, names: names, actionName: "Detect Songs")
                }
            }
            .sheet(item: Binding(get: { artworkFor.map(IdentifiedUUID.init) }, set: { artworkFor = $0?.id })) { target in
                if let seg = segments.first(where: { $0.id == target.id }) {
                    ArtworkEditor(item: item, segment: seg, trackCount: segments.count) { file, all in
                        draft.change(all ? "Set Artwork for All Tracks" : "Set Artwork") { segs in
                            for i in segs.indices where all || segs[i].id == target.id { segs[i].artworkFile = file }
                        }
                    }
                    .environment(lib)
                }
            }
            .alert("TubeTunes", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
        } else {
            ContentUnavailableView("This download no longer exists", systemImage: "questionmark.folder")
        }
    }

    // MARK: - Toolbar & leaving

    @ToolbarContentBuilder
    private func toolbar(_ item: DownloadItem, dirty: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the list (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Save") { draft.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
                .help("Save changes without updating Music (⌘S)")
        }
    }

    private func goBack() {
        if draft.isDirty { showLeavePrompt = true } else { leave() }
    }

    private func leave() {
        player.stop()
        draft.detach()
        onClose()
    }

    // MARK: - Loading

    private func load(_ item: DownloadItem) async {
        if selection == nil { selection = item.segments.first?.id }
        guard let preview = lib.file(item, item.previewFile) else { return }
        await player.load(preview)
        player.applyFades(item.segments)
        if let source = lib.file(item, item.sourceFile) {
            let cache = lib.folder(for: item.id).appendingPathComponent(AudioTools.envelopeCacheName)
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

    // MARK: - Timeline viewport

    private var duration: Double { max(1, item?.duration ?? 1) }
    private var maxZoom: Double { max(1, duration / 3) }
    private var visibleSpan: Double { duration / zoom }
    private var visibleRange: ClosedRange<Double> { viewStart...(viewStart + visibleSpan) }

    /// Zooms keeping the time under `anchor` (fraction of the width) in place.
    private func setZoom(_ newZoom: Double, anchor: Double) {
        let z = min(max(1, newZoom), maxZoom)
        let anchorTime = viewStart + anchor * visibleSpan
        zoom = z
        setViewStart(anchorTime - anchor * (duration / z))
    }

    private func setViewStart(_ t: Double) {
        viewStart = min(max(0, t), max(0, duration - visibleSpan))
    }

    /// Zoom from the slider/buttons: keep the playhead in place if it's visible, else the center.
    private func zoomAroundPlayhead(_ newZoom: Double) {
        let t = player.currentTime
        let anchor = visibleRange.contains(t) ? (t - viewStart) / visibleSpan : 0.5
        setZoom(newZoom, anchor: anchor)
    }

    private func follow(_ t: Double) {
        guard followPlayhead, player.isPlaying, zoom > 1, !visibleRange.contains(t) else { return }
        setViewStart(t - visibleSpan * 0.1)
    }

    /// Starting playback re-engages following, like Logic.
    private func togglePlay() {
        if !player.isPlaying { followPlayhead = true }
        player.toggle()
    }

    private func play(from: Double, until: Double?) {
        followPlayhead = true
        player.play(from: from, until: until)
    }

    /// The user moved the view themselves: stop following the playhead.
    private func scrollManually(to t: Double) {
        followPlayhead = false
        setViewStart(t)
    }

    private func timeline(_ item: DownloadItem) -> some View {
        WaveformTimeline(
            envelope: envelope,
            range: envelopeRange,
            duration: item.duration,
            visible: visibleRange,
            segments: segments,
            chapters: item.chapters,
            selection: selection,
            playhead: player.currentTime,
            onSeek: { player.seek($0) },
            onSelect: { if let id = $0 { selection = id } },
            onMoveEdge: moveEdge
        )
        .background(ScrollZoomCatcher(
            onScroll: { dx, dy, option, fx in
                followPlayhead = false
                if option {
                    setZoom(zoom * (1 + Double(dy) / 200), anchor: Double(fx))
                } else {
                    // Trackpad swipes and mouse wheels both pan the timeline.
                    let delta = abs(dx) >= abs(dy) ? dx : dy
                    scrollManually(to: viewStart - Double(delta) / 900 * visibleSpan)
                }
            },
            onMagnify: { m, fx in
                followPlayhead = false
                setZoom(zoom * (1 + Double(m)), anchor: Double(fx))
            }
        ))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .overlay {
            if envelope.isEmpty { ProgressView("Reading audio…").controlSize(.small) }
        }
        .help("Pinch to zoom, swipe to scroll, drag the edges to trim")
    }

    /// Thin bar showing which part of the video is on screen; drag it to scroll.
    private func overview(_ item: DownloadItem) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = viewStart / duration * w
            let width = max(8, visibleSpan / duration * w)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                ForEach(segments) { seg in
                    Rectangle().fill(Color.accentColor.opacity(seg.included ? 0.35 : 0.1))
                        .frame(width: max(1, seg.duration / duration * w - 1))
                        .offset(x: seg.start / duration * w)
                }
                Capsule().stroke(Color.primary.opacity(0.6), lineWidth: 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .frame(width: width)
                    .offset(x: x0)
                Rectangle().fill(Color.red).frame(width: 1).offset(x: player.currentTime / duration * w)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if overviewDragStart == nil {
                            // Clicking outside the window jumps there; dragging inside moves it.
                            let t = v.startLocation.x / w * duration
                            overviewDragStart = visibleRange.contains(t) ? viewStart : t - visibleSpan / 2
                        }
                        scrollManually(to: (overviewDragStart ?? 0) + v.translation.width / w * duration)
                    }
                    .onEnded { _ in overviewDragStart = nil }
            )
        }
        .frame(height: 10)
        .opacity(zoom > 1.01 ? 1 : 0.35)
    }

    private func transport(_ item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            Button { togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play/Pause (Space)")
            Button { previousTrack() } label: { Image(systemName: "backward.end.fill") }
                .accessibilityLabel("Previous Track")
                .help("Start of this track, or the previous track if already at its start")
            Button { nextTrack() } label: { Image(systemName: "forward.end.fill") }
                .accessibilityLabel("Next Track")
                .help("Start of the next track")
                .disabled(!segments.contains { $0.start > player.currentTime + 0.05 })
            Button { endOfTrack() } label: { Image(systemName: "arrow.right.to.line") }
                .accessibilityLabel("End of Track")
                .help("End of this track")
                .disabled(currentTrack == nil)
            Toggle(isOn: Binding(get: { followPlayhead }, set: { on in
                followPlayhead = on
                if on, !visibleRange.contains(player.currentTime) { setViewStart(player.currentTime - visibleSpan * 0.1) }
            })) {
                Image(systemName: "scope")
            }
            .accessibilityLabel("Follow Playhead")
            .toggleStyle(.button)
            .help("Follow the playhead while playing. Scrolling turns this off; pressing play turns it back on.")
            Text("\(formatTime(player.currentTime, precise: true)) / \(formatTime(item.duration))")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)

            Divider().frame(height: 18)

            Button("Split at Playhead", systemImage: "scissors") { splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .help("Split the track under the playhead (⌘B)")
            Menu {
                Button("Use Chapters (\(item.chapters.count))") { useChapters() }
                    .disabled(item.chapters.isEmpty)
                Button("Detect Songs…") { showDetect = true }
                    .disabled(envelope.isEmpty)
                Button("Single Track (Whole Video)") {
                    replaceSegments(ranges: [0...item.duration], names: [segments.first?.title ?? item.title],
                                    actionName: "Make Single Track")
                }
                Divider()
                Button("Number Tracks 1…\(segments.filter(\.included).count)") {
                    draft.change("Number Tracks") { SegmentBuilder.number(&$0) }
                }
            } label: {
                Label("Split", systemImage: "rectangle.split.3x1")
            }
            .fixedSize()

            Spacer()

            Button { zoomAroundPlayhead(zoom / 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
            Slider(value: Binding(get: { log(zoom) }, set: { zoomAroundPlayhead(exp($0)) }),
                   in: 0...max(0.01, log(maxZoom)))
                .frame(width: 140)
            Button { zoomAroundPlayhead(zoom * 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Track navigation

    /// The track under the playhead.
    private var currentTrack: Segment? {
        let t = player.currentTime
        return segments.first { $0.start - 0.05 <= t && t < $0.end }
    }

    private func jump(to t: Double, select seg: Segment?) {
        if let seg { selection = seg.id }
        player.seek(t)
        followPlayhead = true
        if !visibleRange.contains(t) { setViewStart(t - visibleSpan * 0.1) }
    }

    /// Like a CD player: back to the start of this track, or to the previous track when already
    /// within two seconds of the start.
    private func previousTrack() {
        let t = player.currentTime
        if let cur = currentTrack, t - cur.start > 2 {
            jump(to: cur.start, select: cur)
        } else if let prev = segments.last(where: { $0.start < t - 0.05 && $0.id != currentTrack?.id }) {
            jump(to: prev.start, select: prev)
        } else if let first = segments.first {
            jump(to: first.start, select: first)
        }
    }

    private func nextTrack() {
        guard let next = segments.first(where: { $0.start > player.currentTime + 0.05 }) else { return }
        jump(to: next.start, select: next)
    }

    private func endOfTrack() {
        guard let cur = currentTrack else { return }
        jump(to: max(cur.start, cur.end - 0.05), select: cur)
    }

    // MARK: - Track list

    private var trackList: some View {
        List(selection: $selection) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                HStack(spacing: 8) {
                    Toggle("", isOn: segmentBinding(seg.id, name: seg.included ? "Exclude Track" : "Include Track").included)
                        .labelsHidden().toggleStyle(.checkbox)
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
                    Button("Play") { play(from: seg.start, until: seg.end) }
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
                segment: segmentBinding(seg.id, name: "Edit Track"),
                artworkURL: lib.file(item, seg.artworkFile),
                trackCount: segments.count,
                lookingUp: lookingUp,
                playhead: player.currentTime,
                maxEnd: item.duration,
                onPlay: { from, to in play(from: from, until: to) },
                onChooseArtwork: { artworkFor = seg.id },
                onLookup: { lookup(seg) },
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
        let alreadyAdded = !(item.musicTrackIDs ?? []).isEmpty || segments.contains { $0.musicPersistentID != nil }
        return HStack {
            if let error = item.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).lineLimit(2).font(.callout)
            } else if draft.isDirty {
                Label("Unsaved changes", systemImage: "pencil.circle").foregroundStyle(.orange)
            } else if alreadyAdded && item.status == .needsReview {
                Label("Edited since it was added. Update to apply the changes in Music.", systemImage: "pencil.circle")
                    .foregroundStyle(.orange)
            } else {
                Text("\(included.count) of \(segments.count) tracks will be added")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == .exporting { ProgressView().controlSize(.small) }
            Button(alreadyAdded ? "Update in Music" : "Add to Music") {
                player.pause()
                draft.save()
                Task {
                    await engine.exportAndAdd(itemID)
                    draft.reloadFromLibrary()
                    if lib.item(itemID)?.status == .added { leave() }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled((included.isEmpty && !alreadyAdded) || item.status == .exporting)
            .help(alreadyAdded ? "Re-exports the tracks and replaces the earlier versions in Music" : "")
        }
        .padding(12)
    }

    // MARK: - Editing (every change goes through `history` so it can be undone)

    private func segmentBinding(_ id: UUID, name: String) -> Binding<Segment> {
        Binding(
            get: { draft.segments.first { $0.id == id } ?? .placeholder },
            set: { new in
                draft.change(name, coalesce: true) { segs in
                    if let i = segs.firstIndex(where: { $0.id == id }) { segs[i] = new }
                }
            }
        )
    }

    private func moveEdge(_ id: UUID, _ edge: SegmentEdge, _ time: Double) {
        let duration = item?.duration ?? 0
        draft.change(edge == .start ? "Move Track Start" : "Move Track End", coalesce: true) { segs in
            guard let i = segs.firstIndex(where: { $0.id == id }) else { return }
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
        draft.change("Split Track") { segs in
            guard let i = segs.firstIndex(where: { $0.id == seg.id }) else { return }
            segs[i].end = t
            segs[i].fadeOut = Prefs.fadeOutSplit
            segs.append(second)
        }
        selection = second.id
    }

    private func merge(_ id: UUID) {
        draft.change("Merge Tracks") { segs in
            guard let i = segs.firstIndex(where: { $0.id == id }), i + 1 < segs.count else { return }
            let next = segs.remove(at: i + 1)
            segs[i].end = next.end
            segs[i].fadeOut = next.fadeOut
        }
    }

    private func delete(_ id: UUID) {
        guard segments.count > 1 else { return }
        draft.change("Delete Track") { $0.removeAll { $0.id == id } }
        if selection == id { selection = segments.first?.id }
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
        draft.change("Split by Chapters") { $0 = new }
        selection = new.first?.id
    }

    private func replaceSegments(ranges: [ClosedRange<Double>], names: [String], actionName: String) {
        guard !ranges.isEmpty else { return }
        let template = segments.first ?? .placeholder
        let new = SegmentBuilder.fromRanges(ranges, names: names, template: template)
        draft.change(actionName) { $0 = new }
        selection = new.first?.id
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
            draft.change("Apple Music Lookup") { segs in
                guard let i = segs.firstIndex(where: { $0.id == seg.id }) else { return }
                segs[i].title = meta.title
                segs[i].artist = meta.artist
                segs[i].album = meta.album
                segs[i].albumArtist = meta.albumArtist
                segs[i].trackNumber = meta.trackNumber
                segs[i].trackCount = meta.trackCount
                segs[i].year = meta.year
                segs[i].genre = meta.genre
                segs[i].metadataSource = meta.source
                if let art { segs[i].artworkFile = art }
            }
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
                        CommitTextField("Title", text: $segment.title)
                        CommitTextField("Artist", text: $segment.artist)
                        CommitTextField("Album", text: $segment.album)
                        CommitTextField("Album Artist", text: $segment.albumArtist)
                    }
                }
                HStack {
                    CommitTextField("Track", text: number($segment.trackNumber)).frame(width: 90)
                    CommitTextField("of", text: number($segment.trackCount)).frame(width: 70)
                    CommitTextField("Year", text: $segment.year).frame(width: 110)
                    CommitTextField("Genre", text: $segment.genre)
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

    private func number(_ value: Binding<Int?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(String.init) ?? "" },
                set: { value.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) })
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
