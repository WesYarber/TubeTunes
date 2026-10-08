import Foundation

enum ToolError: LocalizedError {
    case missing(String)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            let formula = name == "ffprobe" ? "ffmpeg" : name
            return "\(name) was not found. Install it with: brew install \(formula)"
        case .failed(let name, let code, let message):
            return "\(name) failed (exit \(code)): \(message)"
        }
    }
}

/// Runs the command-line tools (yt-dlp, ffmpeg) the app is built on.
enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                              NSHomeDirectory() + "/.local/bin"]

    static func path(_ name: String) -> String? {
        searchPaths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // yt-dlp needs to find ffmpeg and deno; GUI apps get a minimal PATH.
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    /// Runs a tool and returns its stdout. `onLine` receives stdout/stderr lines as they arrive.
    @discardableResult
    static func run(_ name: String, _ args: [String],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        guard let exe = path(name) else { throw ToolError.missing(name) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = OutputCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isErr: false) }
        err.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, isErr: true) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.append(out.fileHandleForReading.readDataToEndOfFile(), isErr: false)
                    collector.append(err.fileHandleForReading.readDataToEndOfFile(), isErr: true)
                    if p.terminationStatus == 0 {
                        cont.resume(returning: collector.stdout)
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(throwing: ToolError.failed(name, p.terminationStatus, collector.errorSummary))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var partial = ["", ""]
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, isErr: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        if isErr { err.append(data) } else { out.append(data) }
        if onLine != nil {
            let idx = isErr ? 1 : 0
            partial[idx] += String(decoding: data, as: UTF8.self)
            var parts = partial[idx].components(separatedBy: .newlines)
            partial[idx] = parts.removeLast()
            lines = parts.filter { !$0.isEmpty }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var stdout: Data { lock.withLock { out } }

    var errorSummary: String {
        let text = lock.withLock { String(decoding: err, as: UTF8.self) }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let errors = lines.filter { $0.contains("ERROR") }
        return (errors.isEmpty ? Array(lines.suffix(4)) : errors).joined(separator: "\n")
    }
}
