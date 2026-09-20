import XCTest
@testable import SwiftImmich

final class JustifiedLayoutTests: XCTestCase {
    private func assets(_ ratios: [Double]) -> [AssetSummary] {
        ratios.enumerated().map { AssetSummary(id: "a\($0.offset)", isFavorite: false, isImage: true, ratio: $0.element) }
    }

    func testFullRowsFillTheContainerWidthExactly() {
        let rows = JustifiedLayout.rows(
            for: assets(Array(repeating: 1.5, count: 40)),
            containerWidth: 1000, targetRowHeight: 180, spacing: 8
        )
        XCTAssertGreaterThan(rows.count, 1)
        // Every row except the last is stretched edge to edge.
        for row in rows.dropLast() {
            let total = row.items.reduce(0) { $0 + $1.width } + CGFloat(row.items.count - 1) * 8
            XCTAssertEqual(total, 1000, accuracy: 0.5)
        }
    }

    func testAspectRatiosArePreserved() {
        let rows = JustifiedLayout.rows(for: assets([0.5, 2.0, 1.0, 1.5]), containerWidth: 600, targetRowHeight: 150, spacing: 4)
        for row in rows {
            for item in row.items {
                XCTAssertEqual(item.width / row.height, CGFloat(item.asset.ratio), accuracy: 0.01)
            }
        }
    }

    func testNothingToLayOutGivesNoRows() {
        XCTAssertTrue(JustifiedLayout.rows(for: [], containerWidth: 800, targetRowHeight: 150, spacing: 4).isEmpty)
        XCTAssertTrue(JustifiedLayout.rows(for: assets([1]), containerWidth: 0, targetRowHeight: 150, spacing: 4).isEmpty)
    }

    func testAMissingRatioDoesNotBreakTheRow() {
        let rows = JustifiedLayout.rows(for: assets([0, -1, 1.5]), containerWidth: 500, targetRowHeight: 150, spacing: 4)
        XCTAssertFalse(rows.isEmpty)
        for row in rows { XCTAssertTrue(row.height.isFinite && row.height > 0) }
    }

    /// The Years / All Photos views lay out the whole library at once.
    func testLayingOutAHundredThousandPhotosIsFast() {
        let many = assets((0..<100_000).map { 0.6 + Double($0 % 13) * 0.15 })
        let start = Date()
        let rows = JustifiedLayout.rows(for: many, containerWidth: 1400, targetRowHeight: 180, spacing: 8)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(rows.count, 1000)
        XCTAssertLessThan(elapsed, 1.5, "layout took \(elapsed)s")
    }
}

final class SearchFilterTests: XCTestCase {
    func testDefaultFiltersAreInactive() async throws {
        XCTAssertFalse(SearchFilters().isActive)
        // Regression: this used to depend on the clock not having ticked between two instances.
        let filters = SearchFilters()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(filters.isActive)
    }

    func testAnyChangeMakesFiltersActive() {
        var filters = SearchFilters()
        filters.favoritesOnly = true
        XCTAssertTrue(filters.isActive)
        filters = SearchFilters()
        filters.rating = 3
        XCTAssertTrue(filters.isActive)
        filters = SearchFilters()
        filters.personIds = ["p"]
        XCTAssertTrue(filters.isActive)
    }

    func testRelativeRangesLookBackFromNow() throws {
        var filters = SearchFilters()
        filters.range = .week
        let after = try XCTUnwrap(filters.takenAfter)
        XCTAssertEqual(Date().timeIntervalSince(after), 7 * 86400, accuracy: 5)
        XCTAssertNil(filters.takenBefore)
    }

    func testCustomRangeCoversWholeDays() throws {
        var filters = SearchFilters()
        filters.range = .custom
        let calendar = Calendar.current
        filters.from = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 15))!
        filters.to = calendar.date(from: DateComponents(year: 2024, month: 3, day: 12, hour: 9))!
        let after = try XCTUnwrap(filters.takenAfter)
        let before = try XCTUnwrap(filters.takenBefore)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: after), DateComponents(day: 10, hour: 0))
        // "To" is inclusive, so the limit is the start of the following day.
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: before), DateComponents(day: 13, hour: 0))
    }

    func testSavedSearchSurvivesEncoding() throws {
        var filters = SearchFilters()
        filters.kind = .videos
        filters.country = "Australia"
        filters.rating = 4
        let saved = SavedSearch(name: "Best clips", query: "beach", filters: filters)
        let decoded = try JSONDecoder().decode(SavedSearch.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
    }
}

final class TimelineFilterTests: XCTestCase {
    func testBoundingBoxIsWestSouthEastNorth() {
        XCTAssertEqual(TimelineFilter.area(west: 1, south: 2, east: 3, north: 4).bbox, "1.0,2.0,3.0,4.0")
        XCTAssertNil(TimelineFilter.none.bbox)
    }

    func testOnlyTheMainTimelinesCollapseStacks() {
        XCTAssertTrue(TimelineFilter.none.collapsesStacks)
        XCTAssertTrue(TimelineFilter.favorites.collapsesStacks)
        XCTAssertTrue(TimelineFilter.archive.collapsesStacks)
        XCTAssertFalse(TimelineFilter.album(id: "a", name: "A").collapsesStacks)
        XCTAssertFalse(TimelineFilter.person(id: "p", name: "P").collapsesStacks)
        XCTAssertFalse(TimelineFilter.trash.collapsesStacks)
    }

    func testOnlyTheLibraryIncludesPartnerPhotos() {
        XCTAssertTrue(TimelineFilter.none.includesPartnerPhotos)
        XCTAssertFalse(TimelineFilter.favorites.includesPartnerPhotos)
        XCTAssertFalse(TimelineFilter.trash.includesPartnerPhotos)
    }

    func testFiltersExposeTheIdsTheServerNeeds() {
        XCTAssertEqual(TimelineFilter.tag(id: "t", name: "T").tagId, "t")
        XCTAssertEqual(TimelineFilter.album(id: "a", name: "A").albumId, "a")
        XCTAssertEqual(TimelineFilter.person(id: "p", name: "P").personId, "p")
        XCTAssertTrue(TimelineFilter.trash.isTrashed)
        XCTAssertEqual(TimelineFilter.favorites.isFavorite, true)
        XCTAssertNil(TimelineFilter.none.isFavorite)
    }
}
