import XCTest
@testable import SwiftImmich

/// Timings for a large library, printed so they can be compared before and after changes.
final class BigLibraryBenchmarks: XCTestCase {
    static func makeAssets(_ count: Int) -> [AssetSummary] {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { index in
            date = date.addingTimeInterval(-3600)
            var asset = AssetSummary(id: "asset-\(index)-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", isFavorite: index % 9 == 0, isImage: true, ratio: [1.5, 0.75, 1.0, 1.78][index % 4])
            asset.date = date
            asset.ownerId = "owner-1111-2222-3333"
            return asset
        }
    }

    private func time(_ label: String, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("BENCH \(label): \(String(format: "%.1f", ms)) ms")
        return ms
    }

    func testLayoutOfAHundredThousandPhotos() {
        let assets = Self.makeAssets(100_000)
        let layoutMs = time("layout 100k photos") { _ = JustifiedLayout.rows(for: assets, containerWidth: 1200, targetRowHeight: 180, spacing: 8) }
        XCTAssertLessThan(layoutMs, 1500, "laying out 100k photos should stay well under a second and a half even in a debug build")
        let rows = JustifiedLayout.rows(for: assets, containerWidth: 1200, targetRowHeight: 180, spacing: 8)
        _ = time("cell centres for 100k photos") { _ = GridNavigator.cells(for: rows, spacing: 8) }
    }

    func testDateGroupingOfALargeSearch() {
        let assets = Self.makeAssets(30_000).shuffled()
        let ms = time("group 30k search results by month, once") { _ = FlatGrouping.groups(for: assets, by: .months) }
        XCTAssertLessThan(ms, 1500)
        let ordered = assets.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let orderedMs = time("group 30k already-ordered results") { _ = FlatGrouping.groups(for: ordered, by: .months) }
        XCTAssertLessThan(orderedMs, ms + 50, "ordered input skips the sort")
    }

    func testGroupingKeepsNewestFirstWhateverTheInputOrder() {
        let assets = Self.makeAssets(200)
        let expected = FlatGrouping.groups(for: assets, by: .months).map(\.title)
        XCTAssertEqual(FlatGrouping.groups(for: assets.shuffled(), by: .months).map(\.title), expected)
        let years = FlatGrouping.groups(for: assets, by: .years)
        XCTAssertEqual(years.reduce(0) { $0 + $1.assets.count }, 200)
    }

    func testLayoutMatchesTheOldRulesOnAnAwkwardTrailingRow() {
        let assets = (0..<7).map { AssetSummary(id: "a\($0)", isFavorite: false, isImage: true, ratio: $0 % 2 == 0 ? 1.5 : 0.7) }
        let rows = JustifiedLayout.rows(for: assets, containerWidth: 800, targetRowHeight: 150, spacing: 6)
        XCTAssertEqual(rows.flatMap { $0.items.map(\.asset.id) }, assets.map(\.id), "every photo appears once, in order")
        for row in rows.dropLast() {
            let used = row.items.reduce(0) { $0 + $1.width } + CGFloat(row.items.count - 1) * 6
            XCTAssertEqual(used, 800, accuracy: 0.01)
        }
    }
}

actor GateProbe {
    var running = 0
    var peak = 0
    var order: [Int] = []
    func enter(_ id: Int) { running += 1; peak = max(peak, running); order.append(id) }
    func leave() { running -= 1 }
}

final class FetchGateTests: XCTestCase {
    func testNoMoreThanTheLimitRunAtOnce() async {
        let gate = FetchGate(limit: 3)
        let probe = GateProbe()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<20 {
                group.addTask {
                    await gate.acquire()
                    await probe.enter(id)
                    try? await Task.sleep(for: .milliseconds(20))
                    await probe.leave()
                    await gate.release()
                }
            }
        }
        let peak = await probe.peak
        let entered = await probe.order.count
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(entered, 20)
    }

    func testTheNewestWaiterGoesFirst() async {
        let gate = FetchGate(limit: 1)
        await gate.acquire()   // hold the only slot
        let probe = GateProbe()
        var tasks: [Task<Void, Never>] = []
        for id in 1...3 {
            tasks.append(Task {
                await gate.acquire()
                await probe.enter(id)
                await probe.leave()
                await gate.release()
            })
            try? await Task.sleep(for: .milliseconds(30))   // they queue up in order 1, 2, 3
        }
        await gate.release()
        for task in tasks { await task.value }
        let order = await probe.order
        XCTAssertEqual(order, [3, 2, 1], "what was requested last is what's on screen now")
    }

    func testTheCacheCostFollowsThePixels() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.addRepresentation(rep)
        XCTAssertEqual(ThumbnailLoader.cost(of: image), 100 * 50 * 4)
    }
}

@MainActor
final class BatchedLoadingTests: XCTestCase {
    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.captured = []
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
    }

    func testAllPhotosLoadsEveryMonthButRedrawsInBatches() async throws {
        let months = 60
        let buckets = "[" + (1...months).map { #"{"timeBucket":"20\#(String(format: "%02d", $0 % 30 + 10))-01-01T00:00:00.000Z","count":2}"# }.joined(separator: ",") + "]"
        let assets = #"{"id":["a","b"],"isFavorite":[false,false],"isImage":[true,true],"isTrashed":[false,false],"createdAt":["2024-01-01T00:00:00.000Z","2024-01-01T00:00:00.000Z"],"fileCreatedAt":["2024-01-01T10:00:00.000Z","2024-01-01T10:00:00.000Z"],"duration":[null,null],"livePhotoVideoId":[null,null],"localOffsetHours":[0,0],"ownerId":["me","me"],"projectionType":[null,null],"ratio":[1,1],"thumbhash":[null,null],"visibility":["timeline","timeline"],"stack":[null,null]}"#
        MockURLProtocol.handler = { request in
            if request.path.hasSuffix("/timeline/buckets") { return (200, buckets) }
            if request.path.hasSuffix("/timeline/bucket") { return (200, assets) }
            return (404, "{}")
        }
        let service = try ImmichService(serverURLString: "https://immich.test", apiKey: "k")
        let model = PhotoLibraryModel(service: service, filter: .locked)
        await model.loadBuckets()
        XCTAssertEqual(model.buckets.count, months)

        var redraws = 0
        let watcher = model.objectWillChange.sink { redraws += 1 }
        await model.loadAllAssets()
        watcher.cancel()

        XCTAssertEqual(model.assetsByBucket.count, Set(model.buckets.map(\.timeBucket)).count, "every month ends up loaded")
        XCTAssertLessThan(redraws, 12, "\(redraws) redraws for \(months) months: they should arrive in batches")
    }

    func testTheWaitBetweenRedrawsGrowsWithTheLibrary() {
        XCTAssertLessThan(PhotoLibraryModel.flushInterval(loadedCount: 0), PhotoLibraryModel.flushInterval(loadedCount: 100_000))
        XCTAssertGreaterThan(PhotoLibraryModel.flushInterval(loadedCount: 100_000), 2)
        XCTAssertLessThan(PhotoLibraryModel.flushInterval(loadedCount: 0), 1)
    }
}


final class ThumbnailLoadingTests: XCTestCase {
    private var directory: URL!
    private var original: URL!

    override func setUpWithError() throws {
        original = DiskImageCache.directory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DiskImageCache.directory = directory
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.resetStats()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.binaryHandler = nil
        DiskImageCache.directory = original
        try? FileManager.default.removeItem(at: directory)
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func request(_ id: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://immich.test/api/assets/\(id)/thumbnail")!)
        request.setValue("k", forHTTPHeaderField: "x-api-key")
        return request
    }

    func testEveryThumbnailLoadsAndNoMoreThanEightDownloadAtOnce() async {
        let image = png()
        MockURLProtocol.binaryHandler = { _ in (200, image, 0.05) }
        let loader = ThumbnailLoader()
        let loaded = await withTaskGroup(of: Bool.self) { group in
            for id in 0..<40 { group.addTask { await loader.image(for: "img-\(id)", request: self.request("img-\(id)")) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(loaded, 40, "every thumbnail arrives")
        XCTAssertLessThanOrEqual(MockURLProtocol.stats.peak, 8, "downloads are limited")
        XCTAssertGreaterThan(MockURLProtocol.stats.peak, 1, "but still run in parallel")
    }

    func testPhotosScrolledPastBeforeTheirTurnAreNotDownloaded() async {
        let image = png()
        MockURLProtocol.binaryHandler = { _ in (200, image, 0.15) }
        let loader = ThumbnailLoader()
        let tasks = (0..<60).map { id in Task { await loader.image(for: "past-\(id)", request: self.request("past-\(id)")) } }
        try? await Task.sleep(for: .milliseconds(60))
        for task in tasks.dropLast(4) { task.cancel() }   // scrolled away, leaving the last four on screen
        for task in tasks { _ = await task.value }
        let requested = MockURLProtocol.stats.total
        XCTAssertLessThan(requested, 30, "only \(requested) of 60 were downloaded; the rest were abandoned before starting")
        for id in 56..<60 {
            let again = await loader.image(for: "past-\(id)", request: self.request("past-\(id)"))
            XCTAssertNotNil(again, "the photos still on screen load")
        }
    }

    func testAPhotoAskedForAgainAfterBeingAbandonedStillLoads() async {
        let image = png()
        MockURLProtocol.binaryHandler = { _ in (200, image, 0.2) }
        let loader = ThumbnailLoader()
        let blockers = (0..<8).map { id in Task { _ = await loader.image(for: "busy-\(id)", request: self.request("busy-\(id)")) } }
        let abandoned = Task { await loader.image(for: "again", request: self.request("again")) }
        try? await Task.sleep(for: .milliseconds(30))
        abandoned.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        let image2 = await loader.image(for: "again", request: request("again"))
        XCTAssertNotNil(image2, "a request after a cancelled one is not mistaken for an abandoned one")
        for blocker in blockers { _ = await blocker.value }
    }
}
