import Foundation

/// A plain-text log at ~/Library/Logs/SwiftImmich.log for anything that goes wrong —
/// the server refusing a request, a failed upload, an unexpected error — so a problem
/// can be looked at after the fact instead of being lost when an alert is dismissed.
/// Help > Show Error Log reveals it. It never contains the API key or photo contents.
enum AppLog {
    /// Only changed by tests, so they don't write into the real log.
    nonisolated(unsafe) static var url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SwiftImmich.log")

    private static let queue = DispatchQueue(label: "dev.local.swiftimmich.applog")
    private static let maxBytes = 2 * 1_048_576
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func error(_ message: String) { write("ERROR", message) }
    static func info(_ message: String) { write("INFO", message) }

    /// For a caught error: what was being attempted, and what went wrong.
    static func error(_ context: String, _ error: Error) {
        write("ERROR", "\(context): \(describe(error))")
    }

    static func describe(_ error: Error) -> String {
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "HTTP \(status)" + (message.map { " — \($0.prefix(300))" } ?? "")
        }
        return String(describing: error)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Logs Objective-C exceptions that would otherwise vanish with the crash.
    static func installExceptionHook() {
        NSSetUncaughtExceptionHandler { exception in
            AppLog.error("Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.prefix(12).joined(separator: "\n"))")
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
