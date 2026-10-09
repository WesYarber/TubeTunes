import SwiftUI

/// The single main window: a list of every download that turns into the editor when you open one.
struct ContentView: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @State private var path: [UUID] = []
    @State private var showAdd = false
    @State private var missingTools: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(showAdd: $showAdd) { path.append($0) }
                .navigationDestination(for: UUID.self) { id in
                    EditorView(itemID: id) { if !path.isEmpty { path.removeLast() } }
                        .navigationBarBackButtonHidden(true)
                }
        }
        .frame(minWidth: 960, minHeight: 700)
        .sheet(isPresented: $showAdd) { AddLinkSheet() }
        .safeAreaInset(edge: .top) {
            if !missingTools.isEmpty {
                Text("Missing tools: \(missingTools.joined(separator: ", ")). Install with: brew install yt-dlp ffmpeg")
                    .font(.callout).padding(8).frame(maxWidth: .infinity)
                    .background(.red.opacity(0.15))
            }
        }
        .overlay {
            if engine.waitingForBackgroundSync {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    ProgressView("Finishing a background sync…")
                }
            }
        }
        .onAppear {
            missingTools = ["yt-dlp", "ffmpeg"].filter { Tools.path($0) == nil }
        }
    }
}

// MARK: - Library list

struct LibraryView: View {
    @Binding var showAdd: Bool
    var open: (UUID) -> Void
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.undoManager) private var undoManager
    @State private var search = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All", review = "To Review", inMusic = "In Music", active = "In Progress"
    }

    private func matches(_ item: DownloadItem) -> Bool {
        switch filter {
        case .all: break
        case .review: guard item.status == .needsReview || item.status == .failed else { return false }
        case .inMusic: guard item.status == .added else { return false }
        case .active: guard item.status.isBusy else { return false }
        }
        guard !search.isEmpty else { return true }
        let fields = [item.title, item.channel] + item.segments.flatMap { [$0.title, $0.artist, $0.album] }
        return fields.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private var attention: [DownloadItem] {
        lib.items.filter { $0.status != .added && matches($0) }.sorted { $0.created > $1.created }
    }

    private var inMusic: [DownloadItem] {
        lib.items.filter { $0.status == .added && matches($0) }
            .sorted { ($0.completed ?? $0.created) > ($1.completed ?? $1.created) }
    }

    var body: some View {
        Group {
            if lib.items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing downloaded yet", systemImage: "music.note.tv")
                } description: {
                    Text("Add a YouTube video or playlist link to get started.")
                } actions: {
                    Button("Add Link…") { showAdd = true }
                }
            } else if attention.isEmpty && inMusic.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    if !attention.isEmpty {
                        Section("Needs Attention") {
                            ForEach(attention) { row($0) }
                        }
                    }
                    if !inMusic.isEmpty {
                        Section("In Music") {
                            ForEach(inMusic) { row($0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("TubeTunes")
        .searchable(text: $search, prompt: "Search songs, artists, videos")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await engine.syncAllPlaylists() } } label: {
                    Label("Check Playlists", systemImage: "arrow.clockwise")
                }
                .help("Check monitored playlists for new videos now")
                .disabled(!engine.syncing.isEmpty || lib.playlists.isEmpty)
                Button { showAdd = true } label: { Label("Add Link", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .help("Add a video or playlist link (⌘N)")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings and monitored playlists (⌘,)")
            }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        LibraryRow(item: item, open: { open(item.id) })
            .contentShape(Rectangle())
            .onTapGesture { if !item.segments.isEmpty { open(item.id) } }
            .contextMenu {
                Button("Edit…") { open(item.id) }.disabled(item.segments.isEmpty)
                if let pid = item.segments.first(where: { $0.musicPersistentID != nil })?.musicPersistentID {
                    Button("Show in Music") { Task { try? await MusicApp.reveal(persistentID: pid) } }
                }
                Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: item.url)!) }
                if item.status == .failed { Button("Retry") { engine.retry(item.id) } }
                if item.status.isBusy { Button("Cancel") { engine.cancel(item.id) } }
                Divider()
                Button("Remove from TubeTunes", role: .destructive) { engine.remove(item.id, undoManager: undoManager) }
            }
    }
}

struct LibraryRow: View {
    let item: DownloadItem
    var open: () -> Void
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine

    var body: some View {
        HStack(spacing: 12) {
            VideoThumb(item: item)
            if let art = lib.file(item, item.segments.first?.artworkFile) {
                ArtworkImage(url: art, size: 54)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryTitle).font(.headline).lineLimit(1)
                Text(secondary).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if item.status != .added { StatusBadge(status: item.status) }
                    if let p = lib.playlist(item.playlistID) {
                        Label(p.title, systemImage: "music.note.list")
                    } else {
                        Label("Single link", systemImage: "link")
                    }
                    if let date = item.completed ?? Optional(item.created) {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
                if let progress = lib.progress[item.id], item.status == .downloading {
                    ProgressView(value: progress).frame(maxWidth: 260)
                } else if item.status.isBusy && item.status != .queued {
                    ProgressView().controlSize(.small)
                }
                if let error = item.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            switch item.status {
            case .needsReview:
                Button((item.musicTrackIDs ?? []).isEmpty ? "Add to Music" : "Update in Music") {
                    Task { await engine.exportAndAdd(item.id) }
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Button("Retry") { engine.retry(item.id) }
            default:
                EmptyView()
            }
            if !item.segments.isEmpty {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Single songs show the song; multi-song videos show the video title.
    private var primaryTitle: String {
        if item.segments.count == 1, let s = item.segments.first, !s.title.isEmpty { return s.title }
        return item.title.isEmpty ? item.url : item.title
    }

    private var secondary: String {
        let included = item.includedSegments
        guard let first = item.segments.first else { return item.channel }
        if item.segments.count == 1 { return "\(first.artist) — \(first.album)" }
        return "\(first.artist) — \(included.count) tracks: " + included.prefix(4).map(\.title).joined(separator: ", ")
            + (included.count > 4 ? "…" : "")
    }
}

// MARK: - Add link

struct AddLinkSheet: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var wantPlaylist = false
    @State private var downloadExisting = true
    @State private var autoAddPlaylist = true
    @State private var reviewVideo = Prefs.reviewManualDownloads
    @State private var working = false
    @State private var error: String?
    @State private var confirmDuplicate = false

    private var parsed: LinkParser.Parsed? { LinkParser.parse(text) }
    private var isPlaylist: Bool {
        guard let p = parsed else { return false }
        return p.videoID == nil ? p.listID != nil : (wantPlaylist && p.listID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add from YouTube").font(.title2.bold())
            TextField("Paste a video or playlist link", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            if let p = parsed {
                if p.videoID != nil && p.listID != nil {
                    Picker("This link has both a video and a playlist", selection: $wantPlaylist) {
                        Text("Just this video").tag(false)
                        Text("The whole playlist").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                if isPlaylist {
                    if p.listID?.hasPrefix("RD") == true {
                        Label("This is a YouTube Mix, which changes on its own and can be very long.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Toggle("Download songs already in the playlist", isOn: $downloadExisting)
                    Toggle("Add new songs straight to Music (otherwise they wait for review)", isOn: $autoAddPlaylist)
                    Text("The playlist is checked every \(Int(Prefs.checkIntervalMinutes)) minutes while TubeTunes is running.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Review before adding to Music (trim, split, artwork)", isOn: $reviewVideo)
                }
            } else if !text.isEmpty {
                Text("That doesn't look like a YouTube link.").foregroundStyle(.red)
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isPlaylist ? "Monitor Playlist" : "Download", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil || working)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), LinkParser.parse(s) != nil { text = s }
        }
        .confirmationDialog("You've already downloaded this video.", isPresented: $confirmDuplicate) {
            Button("Download Again") { addVideo() }
        }
    }

    private func add() {
        guard let p = parsed, !working else { return }
        error = nil
        if isPlaylist, let list = p.listID {
            working = true
            Task {
                do {
                    try await engine.addPlaylist(listID: list, downloadExisting: downloadExisting, autoAdd: autoAddPlaylist)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
                working = false
            }
        } else if let vid = p.videoID {
            if lib.hasVideo(vid) { confirmDuplicate = true } else { addVideo() }
        }
    }

    private func addVideo() {
        guard let vid = parsed?.videoID else { return }
        engine.addVideo(id: vid, autoAdd: !reviewVideo)
        dismiss()
    }
}
