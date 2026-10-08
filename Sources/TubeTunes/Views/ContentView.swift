import SwiftUI

enum SidebarItem: Hashable {
    case queue, history, playlists
}

struct ContentView: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @State private var selection: SidebarItem? = .queue
    @State private var showAdd = false
    @State private var missingTools: [String] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Queue", systemImage: "tray.and.arrow.down")
                    .badge(lib.items.filter { $0.status != .added }.count)
                    .tag(SidebarItem.queue)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label("Playlists", systemImage: "music.note.list")
                    .badge(lib.playlists.count)
                    .tag(SidebarItem.playlists)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection ?? .queue {
            case .queue: QueueView()
            case .history: HistoryView()
            case .playlists: PlaylistsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add Link", systemImage: "plus") }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $showAdd) { AddLinkSheet() }
        .safeAreaInset(edge: .top) {
            if !missingTools.isEmpty {
                Text("Missing tools: \(missingTools.joined(separator: ", ")). Install with: brew install yt-dlp ffmpeg")
                    .font(.callout).padding(8).frame(maxWidth: .infinity)
                    .background(.red.opacity(0.15))
            }
        }
        .onAppear {
            missingTools = ["yt-dlp", "ffmpeg"].filter { Tools.path($0) == nil }
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    private var items: [DownloadItem] {
        lib.items.filter { $0.status != .added }.sorted { $0.created > $1.created }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Nothing in the queue", systemImage: "tray",
                                       description: Text("Add a YouTube video or playlist link with the + button."))
            } else {
                List(items) { item in
                    QueueRow(item: item)
                        .contextMenu { contextMenu(item) }
                }
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem {
                Button("Add All Reviewed") {
                    Task {
                        for item in items where item.status == .needsReview { await engine.exportAndAdd(item.id) }
                    }
                }
                .disabled(!items.contains { $0.status == .needsReview })
                .help("Add every track that's ready for review to Music as-is")
            }
        }
    }

    @ViewBuilder private func contextMenu(_ item: DownloadItem) -> some View {
        Button("Edit…") { openWindow(id: "editor", value: item.id) }.disabled(item.segments.isEmpty)
        Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: item.url)!) }
        if item.status == .failed { Button("Retry") { engine.retry(item.id) } }
        if item.status.isBusy { Button("Cancel") { engine.cancel(item.id) } }
        Divider()
        Button("Remove", role: .destructive) { engine.remove(item.id) }
    }
}

struct QueueRow: View {
    let item: DownloadItem
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            VideoThumb(item: item)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? item.url : item.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    StatusBadge(status: item.status)
                    if !item.channel.isEmpty { Text(item.channel).foregroundStyle(.secondary) }
                    if item.segments.count > 1 { Text("· \(item.includedSegments.count) tracks").foregroundStyle(.secondary) }
                    if let p = lib.playlist(item.playlistID) { Text("· \(p.title)").foregroundStyle(.secondary) }
                }
                .font(.caption)
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
                Button("Edit…") { openWindow(id: "editor", value: item.id) }
                Button("Add to Music") { Task { await engine.exportAndAdd(item.id) } }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button("Retry") { engine.retry(item.id) }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - History

struct HistoryView: View {
    @Environment(Library.self) private var lib
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var error: String?

    private struct Entry: Identifiable {
        let item: DownloadItem
        let segment: Segment
        var id: UUID { segment.id }
    }

    private var entries: [Entry] {
        let all = lib.items.flatMap { item in
            item.segments.filter { $0.musicPersistentID != nil }.map { Entry(item: item, segment: $0) }
        }
        let filtered = search.isEmpty ? all : all.filter {
            [$0.segment.title, $0.segment.artist, $0.segment.album, $0.item.title]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
        return filtered.sorted { ($0.segment.addedToMusicAt ?? .distantPast) > ($1.segment.addedToMusicAt ?? .distantPast) }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No tracks yet" : "No matches", systemImage: "music.note",
                                       description: Text(search.isEmpty ? "Tracks you add to Music show up here." : ""))
            } else {
                List(entries) { entry in
                    HStack(spacing: 12) {
                        VideoThumb(item: entry.item)
                        ArtworkImage(url: lib.file(entry.item, entry.segment.artworkFile), size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.segment.title).font(.headline).lineLimit(1)
                            Text("\(entry.segment.artist) — \(entry.segment.album)")
                                .foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 4) {
                                if let p = lib.playlist(entry.item.playlistID) {
                                    Image(systemName: "music.note.list"); Text(p.title)
                                } else {
                                    Image(systemName: "link"); Text("Single link")
                                }
                                Text("· \(formatTime(entry.segment.duration))")
                            }
                            .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let date = entry.segment.addedToMusicAt {
                            Text(date, format: .dateTime.month().day().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Edit…") { openWindow(id: "editor", value: entry.item.id) }
                            .help("Re-trim, re-split or change tags/artwork, then update the track in Music")
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Edit & Update in Music…") { openWindow(id: "editor", value: entry.item.id) }
                        Button("Show in Music") {
                            Task {
                                do { try await MusicApp.reveal(persistentID: entry.segment.musicPersistentID ?? "") }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: entry.item.url)!) }
                    }
                    .onTapGesture(count: 2) { openWindow(id: "editor", value: entry.item.id) }
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, prompt: "Search tracks")
        .alert("Music", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @State private var confirmRemove: Playlist?

    var body: some View {
        Group {
            if lib.playlists.isEmpty {
                ContentUnavailableView("No playlists monitored", systemImage: "music.note.list",
                                       description: Text("Add a playlist link and new videos will download automatically."))
            } else {
                List(lib.playlists) { p in
                    row(p)
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem {
                Button { Task { await engine.syncAllPlaylists() } } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(!engine.syncing.isEmpty)
            }
        }
        .confirmationDialog("Stop monitoring “\(confirmRemove?.title ?? "")”?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Stop Monitoring", role: .destructive) {
                if let p = confirmRemove { lib.removePlaylist(p.id) }
            }
        } message: {
            Text("Tracks already added to Music stay there.")
        }
    }

    private func row(_ p: Playlist) -> some View {
        let downloaded = lib.items.filter { $0.playlistID == p.id }.count
        return HStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.headline)
                Text("\(downloaded) downloaded · \(p.knownVideoIDs.count) seen")
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    if engine.syncing.contains(p.id) {
                        Text("Checking…")
                    } else if let checked = p.lastChecked {
                        Text("Last checked ") + Text(checked, style: .relative) + Text(" ago")
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
                if let error = p.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Toggle("Auto-add to Music", isOn: Binding(
                get: { p.autoAddToMusic },
                set: { v in lib.updatePlaylist(p.id) { $0.autoAddToMusic = v } }))
                .help("Off: new songs wait in the Queue for review")
            Toggle("Monitor", isOn: Binding(
                get: { p.enabled },
                set: { v in lib.updatePlaylist(p.id) { $0.enabled = v } }))
            Menu {
                Button("Check Now") { Task { await engine.sync(p.id) } }
                Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: p.url)!) }
                Divider()
                Button("Stop Monitoring…", role: .destructive) { confirmRemove = p }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 4)
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
