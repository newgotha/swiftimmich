import XCTest
@testable import SwiftImmich

final class ScrubberModelTests: XCTestCase {
    private let buckets: [(key: String, count: Int)] = [
        ("2024-03-01T00:00:00.000Z", 100),
        ("2024-01-01T00:00:00.000Z", 100),
        ("2023-12-01T00:00:00.000Z", 200),
    ]

    func testSlicesCoverTheWholeStripInOrder() {
        let model = ScrubberModel(buckets: buckets)
        XCTAssertEqual(model.slices.count, 3)
        XCTAssertEqual(model.slices.first?.start, 0)
        XCTAssertEqual(model.slices.last?.end ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(model.slices[0].end, 0.25, accuracy: 0.0001)
        XCTAssertEqual(model.slices[2].start, 0.5, accuracy: 0.0001)
    }

    func testPositionMapsToTheMonthUnderIt() {
        let model = ScrubberModel(buckets: buckets)
        XCTAssertEqual(model.slice(at: 0.1)?.key, "2024-03-01T00:00:00.000Z")
        XCTAssertEqual(model.slice(at: 0.3)?.key, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(model.slice(at: 0.9)?.key, "2023-12-01T00:00:00.000Z")
    }

    func testPositionsOutsideTheStripAreClamped() {
        let model = ScrubberModel(buckets: buckets)
        XCTAssertEqual(model.slice(at: -3)?.key, "2024-03-01T00:00:00.000Z")
        XCTAssertEqual(model.slice(at: 7)?.key, "2023-12-01T00:00:00.000Z")
    }

    func testQuietMonthsStayReachable() {
        let model = ScrubberModel(buckets: [("2024-02-01T00:00:00.000Z", 5000), ("2024-01-01T00:00:00.000Z", 1)])
        let quiet = model.slices[1]
        XCTAssertGreaterThan(quiet.end - quiet.start, 0)
    }

    func testYearMarksAppearOncePerYearAtTheirFirstMonth() {
        let marks = ScrubberModel(buckets: buckets).yearMarks
        XCTAssertEqual(marks.map(\.year), ["2024", "2023"])
        XCTAssertEqual(marks[0].position, 0, accuracy: 0.0001)
        XCTAssertEqual(marks[1].position, 0.5, accuracy: 0.0001)
    }

    func testEmptyTimelineHasNothingToScrub() {
        let model = ScrubberModel(buckets: [])
        XCTAssertNil(model.slice(at: 0.5))
        XCTAssertTrue(model.yearMarks.isEmpty)
    }
}

final class ProblemReportTests: XCTestCase {
    func testReportIncludesVersionsAndLog() {
        let text = ProblemReport.build(appVersion: "2.0.0", macOS: "Version 15", server: "v1.130", logLines: ["a", "b"])
        XCTAssertTrue(text.contains("SwiftImmich: 2.0.0"))
        XCTAssertTrue(text.contains("macOS: Version 15"))
        XCTAssertTrue(text.contains("Immich server: v1.130"))
        XCTAssertTrue(text.contains("a\nb"))
    }

    func testEmptyLogIsSaidSo() {
        let text = ProblemReport.build(appVersion: "2.0.0", macOS: "x", server: nil, logLines: [])
        XCTAssertTrue(text.contains("(the log is empty)"))
        XCTAssertFalse(text.contains("Immich server:"))
    }

    func testRecentLogReturnsOnlyTheLastLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("problem-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let lines = ProblemReport.recentLog(at: url, count: 5)
        XCTAssertEqual(lines, ["line 96", "line 97", "line 98", "line 99", "line 100"])
    }

    func testMissingLogGivesNoLines() {
        XCTAssertTrue(ProblemReport.recentLog(at: URL(fileURLWithPath: "/nonexistent/none.log")).isEmpty)
    }
}

final class GridZoomTests: XCTestCase {
    func testZoomStaysInRange() {
        XCTAssertEqual(GridZoom.clamped(10), GridZoom.range.lowerBound)
        XCTAssertEqual(GridZoom.clamped(9999), GridZoom.range.upperBound)
        XCTAssertEqual(GridZoom.clamped(200), 200)
    }

    func testStandardSizeIsInsideTheRange() {
        XCTAssertTrue(GridZoom.range.contains(GridZoom.standard))
    }
}

final class PersonManagementTests: XCTestCase {
    private var service: ImmichService!
    private let personReply = #"{"id":"p1","name":"Ann","isHidden":true,"isFavorite":true,"thumbnailPath":"","updatedAt":"2026-01-01T00:00:00.000Z","birthDate":"1985-03-27"}"#

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "secret-key")
    }

    override func tearDown() { URLProtocol.unregisterClass(MockURLProtocol.self) }

    func testFavoritingSendsOnlyThatField() async throws {
        MockURLProtocol.handler = { _ in (200, self.personReply) }
        let person = try await service.updatePerson(id: "p1", isFavorite: true)
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/people/p1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["isFavorite"] as? Bool, true)
        XCTAssertNil(json["isHidden"])
        XCTAssertNil(json["name"])
        XCTAssertEqual(person.id, "p1")
    }

    func testBirthdayIsSentAsAPlainDate() async throws {
        MockURLProtocol.handler = { _ in (200, self.personReply) }
        var parts = DateComponents(); parts.year = 1985; parts.month = 3; parts.day = 27; parts.hour = 12
        let noon = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: parts))
        _ = try await service.updatePerson(id: "p1", birthDate: noon)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.captured.first).body) as? [String: Any])
        XCTAssertEqual(json["birthDate"] as? String, PersonBirthday.string(from: noon))
        XCTAssertEqual(PersonBirthday.string(from: noon).count, 10)
    }

    func testBirthdayRoundTrips() throws {
        let date = try XCTUnwrap(PersonBirthday.date(from: "1985-03-27"))
        XCTAssertEqual(PersonBirthday.string(from: date), "1985-03-27")
    }

    func testAServerRefusalIsReported() async {
        MockURLProtocol.handler = { _ in (400, #"{"message":"bad"}"#) }
        do {
            _ = try await service.updatePerson(id: "p1", isHidden: true)
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHiddenPeopleAreRequestedOnlyWhenAsked() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"people":[],"total":0,"hidden":0,"hasNextPage":false}"#) }
        _ = try await service.fetchPeople(includeHidden: true)
        _ = try await service.fetchPeople()
        XCTAssertEqual(MockURLProtocol.captured.count, 2)
    }
}

@MainActor
final class GridZoomStoreTests: XCTestCase {
    func testTheStoreKeepsTheSizeInRangeAndAdjusts() {
        let store = GridZoomStore.shared
        let original = store.value
        defer { store.value = original }
        store.reset()
        XCTAssertEqual(store.value, GridZoom.standard)
        store.adjust(by: 30)
        XCTAssertEqual(store.value, GridZoom.standard + 30)
        store.adjust(by: 10_000)
        XCTAssertEqual(store.value, GridZoom.range.upperBound)
        store.adjust(by: -10_000)
        XCTAssertEqual(store.value, GridZoom.range.lowerBound)
    }
}

final class GridNavigatorTests: XCTestCase {
    private typealias Cell = GridLayoutEntry.Cell
    // Row 0: a b c   Row 1: d e   Row 2: f (centres are spread across a 300pt width)
    private let rows: [[Cell]] = [
        [Cell(id: "a", centerX: 50), Cell(id: "b", centerX: 150), Cell(id: "c", centerX: 250)],
        [Cell(id: "d", centerX: 75), Cell(id: "e", centerX: 225)],
        [Cell(id: "f", centerX: 150)],
    ]

    func testLeftAndRightStayInARowThenWrap() {
        XCTAssertEqual(GridNavigator.move(from: "a", .right, rows: rows), "b")
        XCTAssertEqual(GridNavigator.move(from: "c", .right, rows: rows), "d")
        XCTAssertEqual(GridNavigator.move(from: "d", .left, rows: rows), "c")
        XCTAssertEqual(GridNavigator.move(from: "b", .left, rows: rows), "a")
    }

    func testUpAndDownPickTheNearestPhotoInTheNextRow() {
        XCTAssertEqual(GridNavigator.move(from: "c", .down, rows: rows), "e")
        XCTAssertEqual(GridNavigator.move(from: "a", .down, rows: rows), "d")
        XCTAssertEqual(GridNavigator.move(from: "e", .down, rows: rows), "f")
        XCTAssertEqual(GridNavigator.move(from: "f", .up, rows: rows), "d", "ties go to the earlier photo")
        XCTAssertEqual(GridNavigator.move(from: "e", .up, rows: rows), "c")
    }

    func testTheEdgesDoNotMove() {
        XCTAssertNil(GridNavigator.move(from: "a", .left, rows: rows))
        XCTAssertNil(GridNavigator.move(from: "a", .up, rows: rows))
        XCTAssertNil(GridNavigator.move(from: "f", .down, rows: rows))
        XCTAssertNil(GridNavigator.move(from: "f", .right, rows: rows))
    }

    func testWithNothingHighlightedAnyArrowStartsAtTheFirstPhoto() {
        XCTAssertEqual(GridNavigator.move(from: nil, .down, rows: rows), "a")
        XCTAssertEqual(GridNavigator.move(from: "gone", .left, rows: rows), "a")
    }

    func testNoPhotosMeansNoMovement() {
        XCTAssertNil(GridNavigator.move(from: nil, .right, rows: []))
        XCTAssertNil(GridNavigator.move(from: nil, .right, rows: [[]]))
    }

    func testCellCentresFollowEachPhotosWidth() {
        let assets = (0..<2).map { AssetSummary(id: "p\($0)", isFavorite: false, isImage: true, ratio: 1) }
        let row = JustifiedRow(items: [(assets[0], 100), (assets[1], 200)], height: 100)
        let cells = GridNavigator.cells(for: [row], spacing: 10)
        XCTAssertEqual(cells[0][0].centerX, 50)
        XCTAssertEqual(cells[0][1].centerX, 210)
    }
}

@MainActor
final class GridFocusTests: XCTestCase {
    private func selectionWithGrid() -> (GridSelection, [AssetSummary]) {
        let assets = ["a", "b", "c", "d"].map { AssetSummary(id: $0, isFavorite: false, isImage: true, ratio: 1) }
        let selection = GridSelection()
        selection.register(UUID(), GridLayoutEntry(
            order: 0, assets: assets,
            rows: [[.init(id: "a", centerX: 50), .init(id: "b", centerX: 150)], [.init(id: "c", centerX: 50), .init(id: "d", centerX: 150)]],
            filter: .none, activate: { _ in }
        ))
        return (selection, assets)
    }

    func testArrowsMoveTheHighlightAndOnlyWhenAGridIsOnScreen() {
        XCTAssertFalse(GridSelection().moveFocus(.right, extend: false), "no grid, so the arrow keys are left alone")
        let (selection, _) = selectionWithGrid()
        XCTAssertTrue(selection.moveFocus(.right, extend: false))
        XCTAssertEqual(selection.focusedId, "a")
        XCTAssertTrue(selection.moveFocus(.down, extend: false))
        XCTAssertEqual(selection.focusedId, "c")
        XCTAssertEqual(selection.focusedItem?.asset.id, "c")
        XCTAssertEqual(selection.actionTarget?.asset.id, "c")
    }

    func testShiftArrowsSelectWhatTheyPassOver() {
        let (selection, _) = selectionWithGrid()
        _ = selection.moveFocus(.right, extend: false)   // a
        _ = selection.moveFocus(.right, extend: true)    // b
        _ = selection.moveFocus(.down, extend: true)     // d
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(Set(selection.selected.keys), ["a", "b", "d"])
    }

    func testSelectAllTakesEveryLoadedPhoto() {
        let (selection, _) = selectionWithGrid()
        XCTAssertTrue(selection.selectAllLoaded())
        XCTAssertEqual(selection.count, 4)
        XCTAssertFalse(GridSelection().selectAllLoaded())
    }

    func testLeavingSelectionClearsTheHighlight() {
        let (selection, _) = selectionWithGrid()
        _ = selection.moveFocus(.right, extend: false)
        selection.end()
        XCTAssertNil(selection.focusedId)
    }

    func testAPageChangeDropsAGridThatLeftTheScreen() {
        let (selection, _) = selectionWithGrid()
        let token = UUID()
        selection.register(token, GridLayoutEntry(order: 1, assets: [], rows: [], filter: .none, activate: { _ in }))
        selection.unregister(token)
        XCTAssertEqual(selection.layouts.count, 1)
    }
}

final class AccessibilityDescriptionTests: XCTestCase {
    func testAThumbnailIsDescribedForVoiceOver() {
        var asset = AssetSummary(id: "a", isFavorite: true, isImage: true, ratio: 1)
        asset.date = Date(timeIntervalSince1970: 1_800_000_000)
        asset.livePhotoVideoId = "v"
        let text = JustifiedAssetGridView.description(of: asset)
        XCTAssertTrue(text.hasPrefix("Photo, Live Photo, "))
        XCTAssertTrue(text.hasSuffix(", favorite"))
    }

    func testAVideoAndAStackAreDescribed() {
        var video = AssetSummary(id: "v", isFavorite: false, isImage: false, ratio: 1)
        video.stackCount = 3
        XCTAssertEqual(JustifiedAssetGridView.description(of: video), "Video, stack of 3")
    }
}

final class AppearanceTests: XCTestCase {
    func testTheDefaultFollowsTheSystemAndSavedChoicesAreRead() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: AppearanceMode.key)
        defer { if let original { defaults.set(original, forKey: AppearanceMode.key) } else { defaults.removeObject(forKey: AppearanceMode.key) } }

        defaults.removeObject(forKey: AppearanceMode.key)
        XCTAssertEqual(AppearanceMode.saved, .system)
        defaults.set("dark", forKey: AppearanceMode.key)
        XCTAssertEqual(AppearanceMode.saved, .dark)
        defaults.set("nonsense", forKey: AppearanceMode.key)
        XCTAssertEqual(AppearanceMode.saved, .system)
    }

    func testThePaletteChangesWithTheAppearance() throws {
        func rgb(_ color: NSColor, _ name: NSAppearance.Name) throws -> Double {
            var value = 0.0
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                value = Double(color.usingColorSpace(.sRGB)?.brightnessComponent ?? -1)
            }
            return value
        }
        for color in [Palette.cardNS, Palette.toolbarNS, Palette.panelNS, Palette.pillFillNS, Palette.pillTextNS] {
            XCTAssertNotEqual(try rgb(color, .aqua), try rgb(color, .darkAqua))
        }
        XCTAssertGreaterThan(try rgb(Palette.cardNS, .aqua), try rgb(Palette.cardNS, .darkAqua), "cards are light in light mode and dark in dark mode")
        XCTAssertGreaterThan(try rgb(Palette.pillTextNS, .darkAqua), try rgb(Palette.pillTextNS, .aqua), "text is light on dark")
    }
}
