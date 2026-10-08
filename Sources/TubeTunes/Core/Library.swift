import Foundation
import Observation

/// All persistent state: downloads, their tracks, and monitored playlists.
/// Stored as JSON in ~/Library/Application Support/TubeTunes.
@MainActor @Observable
final class Library {
    static let shared = Library()

    var items: [DownloadItem] = []
    var playlists: [Playlist] = []
    /// Transient download progress (0...1) per item.
    var progress: [UUID: Double] = [:]

    let root: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var items: [DownloadItem]
        var playlists: [Playlist]
    }

    private var dbURL: URL { root.appendingPathComponent("library.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("TubeTunes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        purgeRemovedFiles()
    }

    private func load() {
        guard let data = try? Data(contentsOf: dbURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            items = snapshot.items
            playlists = snapshot.playlists
        } catch {
            // Keep the unreadable file rather than overwriting it on the next save.
            let backup = root.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: dbURL, to: backup)
            NSLog("TubeTunes: could not read library: \(error)")
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Snapshot(items: items, playlists: playlists))
            try data.write(to: dbURL, options: .atomic)
        } catch {
            NSLog("TubeTunes: could not save library: \(error)")
        }
    }

    // MARK: - Files

    func folder(for id: UUID) -> URL {
        let url = root.appendingPathComponent("Items/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exportFolder(for id: UUID) -> URL {
        let url = root.appendingPathComponent("Exports/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ item: DownloadItem, _ name: String?) -> URL? {
        guard let name else { return nil }
        return root.appendingPathComponent("Items/\(item.id.uuidString)/\(name)")
    }

    // MARK: - Items

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    func hasVideo(_ videoID: String) -> Bool { items.contains { $0.videoID == videoID } }

    /// Removes the record only; its files stay until the next launch so the removal can be undone.
    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Deletes files left behind by downloads that were removed.
    private func purgeRemovedFiles() {
        let fm = FileManager.default
        let keep = Set(items.map(\.id.uuidString))
        for sub in ["Items", "Exports"] {
            let dir = root.appendingPathComponent(sub)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where UUID(uuidString: name) != nil && !keep.contains(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Playlists

    func playlist(_ id: UUID?) -> Playlist? { playlists.first { $0.id == id } }

    func updatePlaylist(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        save()
    }

    func removePlaylist(_ id: UUID, undoManager: UndoManager? = nil) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let playlist = playlists.remove(at: index)
        save()
        undoManager?.registerUndo(withTarget: self) { lib in
            MainActor.assumeIsolated {
                lib.playlists.insert(playlist, at: min(index, lib.playlists.count))
                lib.save()
                undoManager?.registerUndo(withTarget: lib) { l in
                    MainActor.assumeIsolated { l.removePlaylist(id, undoManager: undoManager) }
                }
            }
        }
        undoManager?.setActionName("Stop Monitoring Playlist")
    }

    /// Changes one playlist setting as an undoable step.
    func setPlaylist<V>(_ id: UUID, _ key: WritableKeyPath<Playlist, V>, _ value: V,
                        actionName: String, undoManager: UndoManager?) {
        guard let old = playlist(id)?[keyPath: key] else { return }
        updatePlaylist(id) { $0[keyPath: key] = value }
        undoManager?.registerUndo(withTarget: self) { lib in
            MainActor.assumeIsolated {
                lib.setPlaylist(id, key, old, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
    }
}
