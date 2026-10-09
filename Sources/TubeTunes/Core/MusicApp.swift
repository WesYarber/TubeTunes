import Foundation

struct MusicError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Music app over AppleScript. Scripts run one at a time on a background
/// queue so a slow Music launch or the first-run permission prompt never freezes the UI.
enum MusicApp {
    struct Added {
        let persistentID: String
        let location: String?
    }

    private static let queue = DispatchQueue(label: "TubeTunes.MusicApp")

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: MusicError(message: "Invalid AppleScript"))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = code == -1743
                        ? "TubeTunes isn't allowed to control Music. Turn it on in System Settings › Privacy & Security › Automation › TubeTunes."
                        : (error[NSAppleScript.errorMessage] as? String ?? "Music returned error \(code)")
                    cont.resume(throwing: MusicError(message: message))
                } else {
                    cont.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    static func add(_ file: URL) async throws -> Added {
        let output = try await run("""
        set f to POSIX file "\(esc(file.path))"
        with timeout of 600 seconds
            tell application "Music"
                set t to add f
                if t is missing value then error "Music did not import the file."
                set pid to persistent ID of t
                set loc to ""
                try
                    set loc to POSIX path of (get location of t)
                end try
                return pid & linefeed & loc
            end tell
        end timeout
        """)
        let parts = output.components(separatedBy: "\n")
        guard let pid = parts.first, !pid.isEmpty else { throw MusicError(message: "Music did not return the new track") }
        let location = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return Added(persistentID: pid, location: location)
    }

    static func delete(persistentID: String) async {
        _ = try? await run("""
        tell application "Music" to delete (every track of library playlist 1 whose persistent ID is "\(esc(persistentID))")
        """)
    }

    static func setTrackNumber(persistentID: String, _ number: Int) async {
        _ = try? await run("""
        tell application "Music" to set track number of (every track of library playlist 1 whose persistent ID is "\(esc(persistentID))") to \(number)
        """)
    }

    static func reveal(persistentID: String) async throws {
        try await run("""
        tell application "Music"
            activate
            reveal (first track of library playlist 1 whose persistent ID is "\(esc(persistentID))")
        end tell
        """)
    }
}
