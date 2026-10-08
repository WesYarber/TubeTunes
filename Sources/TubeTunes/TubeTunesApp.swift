import SwiftUI

struct TubeTunesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var lib = Library.shared
    @State private var engine = Engine.shared

    init() {
        Prefs.register()
        Engine.shared.launch()
    }

    var body: some Scene {
        Window("TubeTunes", id: "main") {
            ContentView()
                .environment(lib)
                .environment(engine)
        }
        .defaultSize(width: 980, height: 680)

        WindowGroup("Edit", id: "editor", for: UUID.self) { $itemID in
            if let itemID {
                EditorView(itemID: itemID)
                    .environment(lib)
                    .environment(engine)
            }
        }
        .defaultSize(width: 1180, height: 820)

        Settings {
            SettingsView()
        }

        MenuBarExtra("TubeTunes", systemImage: "music.note.tv") {
            MenuBarContent()
                .environment(lib)
                .environment(engine)
        }
    }
}

/// Handles tubetunes://add?url=<YouTube link>[&review=0|1][&playlist=1] (for Shortcuts, bookmarklets, etc.).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { handle(url) }
        }
    }

    @MainActor private func handle(_ url: URL) {
        guard url.scheme == "tubetunes", url.host == "add",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let link = query.first(where: { $0.name == "url" })?.value,
              let parsed = LinkParser.parse(link) else { return }
        let flag = { (name: String) in query.first { $0.name == name }?.value }
        if let list = parsed.listID, parsed.videoID == nil || flag("playlist") == "1" {
            Task {
                try? await Engine.shared.addPlaylist(listID: list, downloadExisting: flag("existing") != "0",
                                                     autoAdd: flag("review") != "1")
            }
        } else if let video = parsed.videoID {
            let review = flag("review").map { $0 == "1" } ?? Prefs.reviewManualDownloads
            Engine.shared.addVideo(id: video, autoAdd: !review)
        }
    }
}

struct MenuBarContent: View {
    @Environment(Library.self) private var lib
    @Environment(Engine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let busy = lib.items.filter { $0.status.isBusy }.count
        let review = lib.items.filter { $0.status == .needsReview }.count
        Text(busy > 0 ? "\(busy) in progress" : "Idle")
        if review > 0 { Text("\(review) ready for review") }
        Divider()
        Button("Open TubeTunes") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Check Playlists Now") { Task { await engine.syncAllPlaylists() } }
            .disabled(engine.waitingForBackgroundSync)
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit TubeTunes") { NSApp.terminate(nil) }
    }
}
