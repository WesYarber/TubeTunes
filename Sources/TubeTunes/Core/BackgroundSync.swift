import Foundation
import ServiceManagement

/// One process at a time owns the library: the app while it's open, or the background agent.
/// Held for the life of the process (released automatically on exit).
final class SyncLock {
    static let shared = SyncLock()
    private var fd: Int32 = -1

    private var path: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TubeTunes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sync.lock").path
    }

    /// Returns true if this process holds (or just took) the lock.
    func tryAcquire() -> Bool {
        if fd >= 0 { return true }
        let f = open(path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return true }   // can't create a lock file; don't block syncing over it
        if flock(f, LOCK_EX | LOCK_NB) == 0 {
            fd = f
            return true
        }
        close(f)
        return false
    }
}

/// A per-user launchd agent (~/Library/LaunchAgents) that starts `TubeTunes --background-sync`
/// every few minutes at background priority, even when the app is quit. Each run exits within
/// milliseconds unless a playlist is due or downloads are queued.
///
/// A classic agent is used instead of SMAppService because launchd pins SMAppService agents to the
/// exact code signature, which breaks on every update of an ad-hoc signed app.
enum BackgroundAgent {
    static let label = "net.wesyarber.TubeTunes.sync"
    private static let legacyService = SMAppService.agent(plistName: "\(label).plist")

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static var needsApproval: Bool { false }

    private static func plist(executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "--background-sync"],
            "StartInterval": 300,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/TubeTunes-sync.log").path,
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "net.wesyarber.TubeTunes"],
        ]
    }

    static func setEnabled(_ on: Bool) throws {
        // Clean up the SMAppService registration used by an earlier version.
        if legacyService.status != .notRegistered { try? legacyService.unregister() }

        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: exe),
                                                          format: .xml, options: 0)
            let changed = (try? Data(contentsOf: plistURL)) != data
            if changed {
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: plistURL, options: .atomic)
            }
            if changed || !isLoaded {
                launchctl(["bootout", "\(domain)/\(label)"])
                launchctl(["bootstrap", domain, plistURL.path])
            }
        } else {
            launchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Installs/updates the agent on launch to match the setting (on by default).
    static func syncWithPreference() {
        do { try setEnabled(Prefs.backgroundSync) } catch {
            NSLog("TubeTunes: background agent: \(error)")
        }
    }

    private static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Headless run started by the agent. Exits quickly unless a playlist is due or work is queued.
enum BackgroundSync {
    @MainActor
    static func run() async {
        Prefs.register()
        guard Prefs.backgroundSync, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        // If the app is open it holds the lock and does its own syncing.
        guard SyncLock.shared.tryAcquire() else { return }
        Tools.lowPriority = true
        let engine = Engine.shared
        guard engine.hasBackgroundWork else { return }
        NSLog("Background sync: starting")
        await engine.runBackgroundPass()
        Library.shared.saveNow()
        NSLog("Background sync: done")
    }
}
