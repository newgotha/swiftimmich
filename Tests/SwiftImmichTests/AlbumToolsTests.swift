import ImmichAPI
import XCTest
@testable import SwiftImmich

enum AlbumFixture {
    static func json(id: String, name: String, description: String = "") -> String {
        """
        {"albumName":"\(name)","albumThumbnailAssetId":null,"albumUsers":[],"assetCount":3,"createdAt":"2024-01-01T00:00:00.000Z",
         "description":"\(description)","hasSharedLink":false,"id":"\(id)","isActivityEnabled":false,"shared":false,"updatedAt":"2024-01-01T00:00:00.000Z"}
        """
    }

    static func album(id: String, name: String, description: String = "") throws -> Components.Schemas.AlbumResponseDto {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return formatter.date(from: text) ?? Date(timeIntervalSince1970: 0)
        }
        return try decoder.decode(Components.Schemas.AlbumResponseDto.self, from: Data(json(id: id, name: name, description: description).utf8))
    }
}

final class AlbumOrderTests: XCTestCase {
    private func albums(_ ids: [String]) throws -> [Components.Schemas.AlbumResponseDto] {
        try ids.map { try AlbumFixture.album(id: $0, name: "Album \($0)") }
    }

    func testYourOrderComesFirstAndNewAlbumsFollow() throws {
        let ordered = AlbumOrder.apply(["c", "a"], to: try albums(["a", "b", "c", "d"]))
        XCTAssertEqual(ordered.map(\.id), ["c", "a", "b", "d"])
    }

    func testAlbumsThatNoLongerExistAreIgnored() throws {
        XCTAssertEqual(AlbumOrder.apply(["gone", "b"], to: try albums(["a", "b"])).map(\.id), ["b", "a"])
        XCTAssertEqual(AlbumOrder.apply([], to: try albums(["a", "b"])).map(\.id), ["a", "b"])
    }

    func testDraggingRowsDownAndUp() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(AlbumOrder.moved(ids, from: IndexSet(integer: 0), to: 3), ["b", "c", "a", "d"], "drag the first row to just before the fourth")
        XCTAssertEqual(AlbumOrder.moved(ids, from: IndexSet(integer: 3), to: 1), ["a", "d", "b", "c"])
        XCTAssertEqual(AlbumOrder.moved(ids, from: IndexSet(integer: 1), to: 4), ["a", "c", "d", "b"], "to the very end")
        XCTAssertEqual(AlbumOrder.moved(ids, from: IndexSet(integer: 2), to: 0), ["c", "a", "b", "d"], "to the very top")
    }

    func testTheOrderIsSavedAndReset() {
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: AlbumOrder.key)
        defer { if let original { defaults.set(original, forKey: AlbumOrder.key) } else { defaults.removeObject(forKey: AlbumOrder.key) } }
        AlbumOrder.save(["x", "y"])
        XCTAssertEqual(AlbumOrder.saved, ["x", "y"])
        AlbumOrder.reset()
        XCTAssertEqual(AlbumOrder.saved, [])
    }
}

final class AlbumDownloadTests: XCTestCase {
    private var service: ImmichService!

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        MockURLProtocol.binaryHandler = nil
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "secret-key")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.binaryHandler = nil
    }

    func testTheArchivePlanAsksForTheAlbumAndReadsTheParts() async throws {
        MockURLProtocol.handler = { _ in (201, #"{"archives":[{"assetIds":["a","b"],"size":100},{"assetIds":["c"],"size":50}],"totalSize":150}"#) }
        let plan = try await service.archivePlan(forAlbum: "album-1")
        XCTAssertEqual(plan.archives, [["a", "b"], ["c"]])
        XCTAssertEqual(plan.totalBytes, 150)
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/download/info")
        XCTAssertEqual(request.headers["x-api-key"], "secret-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["albumId"] as? String, "album-1")
    }

    func testARefusedPlanIsReported() async {
        MockURLProtocol.handler = { _ in (403, #"{"message":"no access"}"#) }
        do {
            _ = try await service.archivePlan(forAlbum: "album-1")
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(message, "no access")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnArchiveIsSavedToAFileAndACleanFailureLeavesNothingBehind() async throws {
        let zip = Data([0x50, 0x4B, 3, 4, 1, 2, 3])
        MockURLProtocol.binaryHandler = { request in
            request.path == "/api/download/archive" ? (200, zip, 0) : (500, Data(), 0)
        }
        let file = try await service.downloadArchive(assetIds: ["a", "b"])
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), zip)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MockURLProtocol.captured.first).body) as? [String: Any])
        XCTAssertEqual(body["assetIds"] as? [String], ["a", "b"])

        MockURLProtocol.binaryHandler = { _ in (500, Data("oops".utf8), 0) }
        do {
            _ = try await service.downloadArchive(assetIds: ["a"])
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, _) {
            XCTAssertEqual(status, 500)
        }
    }

    func testChangingADescriptionSendsOnlyThatField() async throws {
        MockURLProtocol.handler = { _ in (200, AlbumFixture.json(id: "album-1", name: "Trip", description: "Summer")) }
        let updated = try await service.updateAlbum(id: "album-1", description: "Summer")
        XCTAssertEqual(updated.description, "Summer")
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "PATCH")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["description"] as? String, "Summer")
        XCTAssertNil(body["albumName"])
    }
}

final class NotificationTests: XCTestCase {
    func testImportNoticesSaySensibleThings() {
        XCTAssertEqual(ImportNotice.make(uploaded: 12, failed: 0, stopReason: nil, wasCancelledByUser: false)?.body, "12 photos were added to your library.")
        XCTAssertEqual(ImportNotice.make(uploaded: 1, failed: 0, stopReason: nil, wasCancelledByUser: false)?.body, "1 photo was added to your library.")
        let problems = ImportNotice.make(uploaded: 5, failed: 2, stopReason: nil, wasCancelledByUser: false)
        XCTAssertEqual(problems?.title, "Import finished with problems")
        XCTAssertTrue(problems?.body.contains("5 uploaded, 2 couldn't be imported") == true)
        XCTAssertEqual(ImportNotice.make(uploaded: 0, failed: 3, stopReason: nil, wasCancelledByUser: false)?.body.hasPrefix("3 couldn't"), true)
    }

    func testAStoppedImportSaysWhy_AndNothingHappenedMeansNoNotice() {
        XCTAssertEqual(ImportNotice.make(uploaded: 4, failed: 0, stopReason: "The server can't be reached.", wasCancelledByUser: false)?.title, "Import stopped")
        XCTAssertNil(ImportNotice.make(uploaded: 0, failed: 0, stopReason: nil, wasCancelledByUser: false), "nothing new is not news")
        XCTAssertNil(ImportNotice.make(uploaded: 9, failed: 1, stopReason: nil, wasCancelledByUser: true), "you stopped it yourself")
    }

    private func comment(_ author: String, _ text: String, at seconds: TimeInterval, mine: Bool = false) -> CommentWatch.Comment {
        .init(author: author, text: text, date: Date(timeIntervalSince1970: seconds), isMine: mine)
    }

    func testOnlyNewCommentsFromOtherPeopleCount() {
        let all = [comment("Ann", "old", at: 100), comment("Ann", "new", at: 300), comment("Me", "mine", at: 400, mine: true), comment("Bo", "newer", at: 500)]
        let fresh = CommentWatch.newComments(all, since: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(fresh.map(\.text), ["new", "newer"])
    }

    func testCommentNoticesNameTheAlbumAndAuthor() {
        XCTAssertNil(CommentWatch.notice(album: "Trip", comments: []))
        let one = CommentWatch.notice(album: "Trip", comments: [comment("Ann", "Lovely!", at: 1)])
        XCTAssertEqual(one?.title, "Ann commented in “Trip”")
        XCTAssertEqual(one?.body, "Lovely!")
        let many = CommentWatch.notice(album: "Trip", comments: [comment("Ann", "a", at: 1), comment("Bo", "b", at: 2)])
        XCTAssertEqual(many?.title, "2 new comments in “Trip”")
        XCTAssertEqual(many?.body, "Bo: b")
    }

    func testTheLastLookIsRemembered() {
        let defaults = UserDefaults.standard
        let original = defaults.dictionary(forKey: "commentLastSeen")
        defer { if let original { defaults.set(original, forKey: "commentLastSeen") } else { defaults.removeObject(forKey: "commentLastSeen") } }
        defaults.removeObject(forKey: "commentLastSeen")
        XCTAssertNil(CommentWatch.lastSeen("album-x"))
        CommentWatch.markSeen("album-x", at: Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(CommentWatch.lastSeen("album-x"), Date(timeIntervalSince1970: 1234))
    }

    func testNotificationsAreOffOutsideARealApp() {
        XCTAssertFalse(Notifier.isAvailable, "tests run without an app bundle, so they can never pop up notifications")
    }
}

final class PinLocationTests: XCTestCase {
    func testAPinRoundTripsAndPrintsReadably() {
        let pin = PinLocation(latitude: -33.8688, longitude: 151.2093)
        XCTAssertEqual(PinLocation(pin.coordinate), pin)
        XCTAssertEqual(pin.text, "-33.8688°, 151.2093°")
        XCTAssertNotEqual(pin, PinLocation(latitude: -33.8688, longitude: 151.2))
    }
}
