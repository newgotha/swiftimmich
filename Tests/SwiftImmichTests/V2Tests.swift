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
