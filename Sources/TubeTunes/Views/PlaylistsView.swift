import SwiftUI

struct PlaylistsView: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.undoManager) private var undoManager
    @State private var confirmRemove: Playlist?

    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New videos in these playlists are downloaded automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await engine.syncAllPlaylists() } } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(!engine.syncing.isEmpty || lib.playlists.isEmpty)
                Button { showAdd = true } label: { Label("Add Playlist…", systemImage: "plus") }
            }
            .padding(12)
            Divider()
            if lib.playlists.isEmpty {
                ContentUnavailableView("No playlists monitored", systemImage: "music.note.list",
                                       description: Text("Add a playlist link and new videos will download automatically."))
            } else {
                List(lib.playlists) { p in
                    row(p)
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddLinkSheet() }
        .confirmationDialog("Stop monitoring “\(confirmRemove?.title ?? "")”?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Stop Monitoring", role: .destructive) {
                if let p = confirmRemove { lib.removePlaylist(p.id, undoManager: undoManager) }
            }
        } message: {
            Text("Tracks already added to Music stay there. You can undo this with ⌘Z.")
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
                set: { v in lib.setPlaylist(p.id, \.autoAddToMusic, v, actionName: "Change Auto-Add", undoManager: undoManager) }))
                .help("Off: new songs wait in the Queue for review")
            Toggle("Monitor", isOn: Binding(
                get: { p.enabled },
                set: { v in lib.setPlaylist(p.id, \.enabled, v, actionName: "Change Monitoring", undoManager: undoManager) }))
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

