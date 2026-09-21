import AppKit
import SwiftUI
import XCTest
@testable import SwiftImmich

/// A stub of the parts of the Immich API a photo grid needs, so real views can be rendered.
private enum GridFixtures {
    static let buckets = #"[{"timeBucket":"2026-09-01T00:00:00.000Z","count":4}]"#

    static var assets: String {
        let ids = (1...4).map { "\"asset-\($0)\"" }.joined(separator: ",")
        func column(_ value: String) -> String { "[" + Array(repeating: value, count: 4).joined(separator: ",") + "]" }
        return """
        {"id":[\(ids)],"isFavorite":\(column("false")),"isImage":\(column("true")),"isTrashed":\(column("false")),
         "createdAt":\(column("\"2026-09-01T00:00:00.000Z\"")),"fileCreatedAt":\(column("\"2026-09-01T10:00:00.000Z\"")),
         "duration":\(column("null")),"livePhotoVideoId":\(column("null")),"localOffsetHours":\(column("0")),
         "ownerId":\(column("\"me\"")),"projectionType":\(column("null")),"ratio":[1.5,1,0.75,1.5],
         "thumbhash":\(column("null")),"visibility":\(column("\"timeline\"")),"stack":\(column("null"))}
        """
    }
}

/// Catches the class of bug that froze the app in 2.0: a screen that redraws itself in a
/// loop. It renders the real photo grid and viewer in a window and fails if the main
/// thread stays busy while nothing is happening.
@MainActor
final class RenderStormTests: XCTestCase {
    private var window: NSWindow?

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.captured = []
        MockURLProtocol.handler = { request in
            if request.path.hasSuffix("/timeline/buckets") { return (200, GridFixtures.buckets) }
            if request.path.hasSuffix("/timeline/bucket") { return (200, GridFixtures.assets) }
            return (404, #"{"message":"not in this test"}"#)
        }
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Lets the window run for a while and reports how much of that time the process spent computing.
    private func busyFraction(over seconds: Double) async throws -> Double {
        let before = cpuSeconds()
        let started = Date()
        try await Task.sleep(for: .seconds(seconds))
        return (cpuSeconds() - before) / Date().timeIntervalSince(started)
    }

    func testAGridAndAPhotoViewerSettleInsteadOfRedrawingForever() async throws {
        _ = NSApplication.shared
        let service = try ImmichService(serverURLString: "https://immich.test", apiKey: "test-key")
        let selection = GridSelection()
        selection.service = service

        // Shaped like the app's own window: a split view whose detail column is a navigation
        // stack, in a titled window with a toolbar. Toolbar updates were part of the 2.0 freeze.
        let root = NavigationSplitView {
            List { Label("Library", systemImage: "photo.on.rectangle") }.listStyle(.sidebar)
        } detail: {
            NavigationStack { PhotoGridView(service: service, filter: .locked) }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
            .environmentObject(ViewerTransition())
            .environmentObject(selection)
            .environmentObject(AlbumMembership())
            .environmentObject(PeopleDirectory())
            .environmentObject(SearchModel())
            .environmentObject(TransferCenter())
            .environmentObject(LockedFolderSession())

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.orderFrontRegardless()
        self.window = window

        try await Task.sleep(for: .seconds(2))
        let entry = try XCTUnwrap(selection.layouts.values.first, "the grid never loaded its photos")
        XCTAssertEqual(entry.assets.count, 4)

        let gridBusy = try await busyFraction(over: 2)
        XCTAssertLessThan(gridBusy, 0.5, "the grid keeps the main thread busy (\(Int(gridBusy * 100))% of a core) with nothing happening")

        entry.activate(entry.assets[0])
        try await Task.sleep(for: .seconds(1.5))
        let viewerBusy = try await busyFraction(over: 2)
        XCTAssertLessThan(viewerBusy, 0.5, "an open photo keeps the main thread busy (\(Int(viewerBusy * 100))% of a core) with nothing happening")
    }
}

final class HangWatchdogTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var hangs: [TimeInterval] = []
        private var recoveries: [TimeInterval] = []
        func hang(_ s: TimeInterval) { lock.lock(); hangs.append(s); lock.unlock() }
        func recover(_ s: TimeInterval) { lock.lock(); recoveries.append(s); lock.unlock() }
        var counts: (hangs: Int, recoveries: Int) { lock.lock(); defer { lock.unlock() }; return (hangs.count, recoveries.count) }
        var firstHang: TimeInterval? { lock.lock(); defer { lock.unlock() }; return hangs.first }
    }

    @MainActor
    func testABlockedMainThreadIsReportedOnceAndRecoveryToo() async throws {
        let events = Events()
        let watchdog = HangWatchdog(threshold: 0.4, beatInterval: 0.05, onHang: events.hang, onRecover: events.recover)
        watchdog.start()
        defer { watchdog.stop() }

        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(events.counts.hangs, 0, "a responsive main thread is not a hang")

        Thread.sleep(forTimeInterval: 1.2)   // the main thread is stuck
        try await Task.sleep(for: .seconds(0.5))

        XCTAssertEqual(events.counts.hangs, 1, "one freeze is reported once, not repeatedly")
        XCTAssertGreaterThanOrEqual(events.firstHang ?? 0, 0.4)
        XCTAssertEqual(events.counts.recoveries, 1)
    }

    @MainActor
    func testAResponsiveAppNeverTriggersIt() async throws {
        let events = Events()
        let watchdog = HangWatchdog(threshold: 0.4, beatInterval: 0.05, onHang: events.hang, onRecover: events.recover)
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertEqual(events.counts.hangs, 0)
        XCTAssertEqual(events.counts.recoveries, 0)
    }
}

final class HangSummaryTests: XCTestCase {
    func testTheBusiestAppFunctionsAreListed() {
        let sample = """
        Call graph:
            959 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 959 start  (in dyld) + 6688  [0x1]
            +   959 main  (in SwiftImmich) + 36  [0x2]  SwiftImmichApp.swift:0
            +     900 PhotoGridView.body.getter  (in SwiftImmich) + 404  [0x3]  PhotoGridView.swift:103
            +     !   40 JustifiedAssetGridView.body.getter  (in SwiftImmich) + 384  [0x4]  JustifiedAssetGridView.swift:86
            +     !   30 PhotoGridView.body.getter  (in SwiftImmich) + 692  [0x5]  PhotoGridView.swift:172
            700 Thread_2   DispatchQueue_9: com.apple.root.utility-qos  (concurrent)
            + 700 HangWatchdog.watch()  (in SwiftImmich) + 328  [0x6]
        """
        let top = HangSummary.topFrames(in: sample)
        XCTAssertEqual(top.first, "959  main")
        XCTAssertTrue(top.contains("930  PhotoGridView.body.getter"))
        XCTAssertTrue(top.contains("40  JustifiedAssetGridView.body.getter"))
        XCTAssertFalse(top.contains { $0.contains("dyld") })
        XCTAssertFalse(top.contains { $0.contains("HangWatchdog") }, "only the main thread matters")
    }

    func testAFreezeAppearsInTheProblemReport() {
        let text = ProblemReport.build(appVersion: "2.2.0", macOS: "x", server: nil, logLines: ["a"], hangSummary: ["900  PhotoGridView.body.getter"])
        XCTAssertTrue(text.contains("## The app froze"))
        XCTAssertTrue(text.contains("900  PhotoGridView.body.getter"))
        let quiet = ProblemReport.build(appVersion: "2.2.0", macOS: "x", server: nil, logLines: ["a"])
        XCTAssertFalse(quiet.contains("The app froze"))
    }
}

/// The 2.0 freeze came from `@AppStorage` in the photo grids. This can't be reproduced in a
/// test window, so the pattern itself is fenced off: preferences reach the grids through a
/// store that only publishes when its own value changes (see `GridZoomStore`).
final class GridGuardrailTests: XCTestCase {
    func testThePhotoGridsDoNotUseAppStorage() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SwiftImmich")
        for name in ["JustifiedAssetGridView.swift", "PhotoGridView.swift", "FlatAssetGridView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("@AppStorage"), "\(name) must not use @AppStorage — it made every grid redraw in a loop while a photo was open. Use an ObservableObject store instead.")
        }
    }
}
