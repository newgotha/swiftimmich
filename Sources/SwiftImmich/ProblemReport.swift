import AppKit
import Foundation

/// "Help > Report a Problem…": gathers what a bug report needs into text on the clipboard
/// and opens the issue page. The log holds errors and file names, never the API key.
enum ProblemReport {
    static func build(appVersion: String, macOS: String, server: String?, logLines: [String]) -> String {
        var text = """
        ## What happened

        (Describe what you were doing and what went wrong.)

        ## Details

        - SwiftImmich: \(appVersion)
        - macOS: \(macOS)
        """
        if let server { text += "\n- Immich server: \(server)" }
        text += "\n\n## Recent log\n\n```\n"
        text += logLines.isEmpty ? "(the log is empty)" : logLines.joined(separator: "\n")
        text += "\n```\n"
        return text
    }

    /// The last `count` lines of the log file, oldest first.
    static func recentLog(at url: URL = AppLog.url, count: Int = 60) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data.suffix(64_000), as: UTF8.self)
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }

    @MainActor
    static func start(serverVersion: String? = nil) {
        let info = Bundle.main.infoDictionary
        let report = build(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            server: serverVersion,
            logLines: recentLog()
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Report a Problem"
        alert.informativeText = "A report with your app and macOS versions and the recent error log is on your clipboard. Paste it into the issue that opens next, and describe what went wrong. Look it over first — the log can mention file names."
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/\(AppInfo.repository)/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// How large the photo thumbnails are: the target row height of the justified grids.
enum GridZoom {
    static let key = "gridRowHeight"
    static let range: ClosedRange<Double> = 90...360
    static let standard = 180.0

    static func clamped(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }
}


/// Holds the thumbnail size. Kept out of `@AppStorage`, which re-renders every view that uses
/// it whenever *any* preference changes — and the toolbar writes preferences constantly, so
/// each photo grid redrew in a loop while a photo was open.
@MainActor
final class GridZoomStore: ObservableObject {
    static let shared = GridZoomStore()

    @Published var value: Double {
        didSet {
            let limited = GridZoom.clamped(value)
            if limited != value { value = limited; return }
            UserDefaults.standard.set(value, forKey: GridZoom.key)
        }
    }

    private init() {
        value = GridZoom.clamped(UserDefaults.standard.object(forKey: GridZoom.key) as? Double ?? GridZoom.standard)
    }

    func adjust(by step: Double) { value += step }
    func reset() { value = GridZoom.standard }
}
