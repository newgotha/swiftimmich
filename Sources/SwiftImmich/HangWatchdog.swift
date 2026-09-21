import AppKit
import Foundation

/// Notices when the app's main thread stops responding, so a freeze leaves evidence behind.
///
/// The main thread updates a heartbeat a few times a second. A separate thread watches it:
/// if the heartbeat goes stale for `threshold` seconds the interface is frozen (or being
/// redrawn in a loop), and `onHang` runs — on the watchdog thread, since the main one is
/// the thing that's stuck. `onRecover` runs once the main thread is responsive again.
final class HangWatchdog: @unchecked Sendable {
    private let threshold: TimeInterval
    private let beatInterval: TimeInterval
    private let onHang: @Sendable (TimeInterval) -> Void
    private let onRecover: @Sendable (TimeInterval) -> Void

    private let lock = NSLock()
    /// Uptime rather than the wall clock: it stands still while the Mac sleeps, so waking
    /// up isn't mistaken for a freeze.
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private var hangStart: TimeInterval?
    private var running = false
    /// A run-loop timer in the common modes, so it keeps beating while a dialog, menu or
    /// window drag is running its own loop (a main-queue timer stops in those).
    private var timer: CFRunLoopTimer?

    init(
        threshold: TimeInterval = 6,
        beatInterval: TimeInterval = 0.25,
        onHang: @escaping @Sendable (TimeInterval) -> Void,
        onRecover: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) {
        self.threshold = threshold
        self.beatInterval = beatInterval
        self.onHang = onHang
        self.onRecover = onRecover
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lastBeat = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), beatInterval, 0, 0) { [weak self] _ in
            self?.beat()
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        self.timer = timer

        let watcher = Thread { [weak self] in self?.watch() }
        watcher.name = "SwiftImmich hang watchdog"
        watcher.qualityOfService = .utility
        watcher.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
    }

    private func beat() {
        lock.lock()
        lastBeat = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: beatInterval)
            lock.lock()
            let stillRunning = running
            let now = ProcessInfo.processInfo.systemUptime
            let stale = now - lastBeat
            let startedAt = hangStart
            var event: (hung: Bool, seconds: TimeInterval)?
            if stillRunning {
                if startedAt == nil, stale >= threshold {
                    // A paused process (or one that just woke) looks stale to begin with, and its
                    // main thread beats again straight away. Only a beat that stays missing is a freeze.
                    let observedBeat = lastBeat
                    lock.unlock()
                    Thread.sleep(forTimeInterval: beatInterval * 3)
                    lock.lock()
                    if lastBeat == observedBeat, running {
                        hangStart = observedBeat
                        event = (true, ProcessInfo.processInfo.systemUptime - observedBeat)
                    }
                } else if let startedAt, stale < threshold {
                    hangStart = nil
                    event = (false, now - startedAt)
                }
            }
            lock.unlock()

            guard stillRunning else { return }
            if let event { event.hung ? onHang(event.seconds) : onRecover(event.seconds) }
        }
    }
}

/// What the app does when the watchdog fires: save a stack sample of itself, remember it,
/// and offer to attach it to a problem report.
enum HangDiagnostics {
    static let pendingKey = "unreportedHangSample"
    private static let keepSamples = 3

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SwiftImmich Hangs")
    }

    nonisolated(unsafe) static var watchdog: HangWatchdog?

    @MainActor
    static func install() {
        let watchdog = HangWatchdog(
            onHang: { seconds in
                AppLog.error(String(format: "The window stopped responding (%.0f s so far); saving a stack sample", seconds))
                captureSample()
            },
            onRecover: { seconds in
                AppLog.info(String(format: "The window responded again after %.0f s", seconds))
                DispatchQueue.main.async { offerReport() }
            }
        )
        watchdog.start()
        self.watchdog = watchdog

        // For checking the watchdog itself: `defaults write dev.local.swiftimmich debugFreezeSeconds -float 10`
        // freezes the window for that long, once, shortly after the next launch.
        if let seconds = UserDefaults.standard.object(forKey: "debugFreezeSeconds") as? Double, seconds > 0 {
            UserDefaults.standard.removeObject(forKey: "debugFreezeSeconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Thread.sleep(forTimeInterval: seconds) }
        }
    }

    /// Runs the system `sample` tool against this process; it works from outside, so it still
    /// sees the stuck main thread.
    static func captureSample() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("hang-\(stamp).txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard fm.fileExists(atPath: file.path) else {
                AppLog.error("sample saved nothing (exit \(process.terminationStatus)): \(text.prefix(300))")
                return
            }
        } catch {
            AppLog.error("couldn't run sample", error)
            return
        }
        UserDefaults.standard.set(file.path, forKey: pendingKey)
        prune()
        AppLog.info("hang sample saved to \(file.path)")
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("hang-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in files.dropFirst(keepSamples) { try? FileManager.default.removeItem(at: old) }
    }

    /// The saved sample, if one hasn't been dealt with yet.
    static var pendingSample: URL? {
        guard let path = UserDefaults.standard.string(forKey: pendingKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// After a freeze — right away if the app recovered, or on the next launch if it had to be
    /// force-quit — offers to send the evidence along with a problem report.
    @MainActor
    static func offerReport() {
        guard let sample = pendingSample else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)

        let alert = NSAlert()
        alert.messageText = "SwiftImmich stopped responding"
        alert.informativeText = "The app froze for a while. A technical snapshot of what it was doing was saved, and can be included in a problem report to help get it fixed."
        alert.addButton(withTitle: "Report a Problem…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            ProblemReport.start(hangSample: sample)
        }
    }
}

/// Boils a `sample` output down to the parts that matter for a bug report.
enum HangSummary {
    /// The app's own functions on the main thread in the sample, busiest first, as "count  function".
    /// Other threads are left out: the watchdog's own thread is always in there taking the sample.
    static func topFrames(in sample: String, limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        var inMainThread = !sample.contains("main-thread")   // no marker: take everything
        for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
            // A thread's own heading sits at the top indent, e.g. "    959 Thread_1   DispatchQueue_1: ...main-thread".
            if line.hasPrefix("    "), line.dropFirst(4).first?.isNumber == true, line.contains("Thread_") {
                inMainThread = line.contains("main-thread")
                continue
            }
            guard inMainThread, line.contains("(in SwiftImmich)") else { continue }
            let trimmed = line.drop { " +!:|".contains($0) }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[0]) else { continue }
            var name = String(parts[1])
            if let range = name.range(of: "  (in SwiftImmich)") { name = String(name[..<range.lowerBound]) }
            counts[name, default: 0] += count
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { "\($0.value)  \($0.key)" }
    }

    static func summary(of url: URL, limit: Int = 12) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return topFrames(in: String(decoding: data, as: UTF8.self), limit: limit)
    }
}
