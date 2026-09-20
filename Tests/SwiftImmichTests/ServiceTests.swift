import ImmichAPI
import XCTest
@testable import SwiftImmich

/// Answers every request from a closure, so `ImmichService` can be exercised without a
/// server: what it sends, and how it reacts to what comes back.
final class MockURLProtocol: URLProtocol {
    struct Captured {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((Captured) -> (status: Int, body: String))?
    nonisolated(unsafe) static var captured: [Captured] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "immich.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
        let captured = Captured(method: request.httpMethod ?? "", path: request.url?.path ?? "", headers: headers, body: body)
        Self.captured.append(captured)

        let reply = Self.handler?(captured) ?? (status: 404, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ServiceTests: XCTestCase {
    private var service: ImmichService!

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "secret-key")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
    }

    func testEveryRequestCarriesTheAPIKey() async throws {
        MockURLProtocol.handler = { _ in (200, "[]") }
        _ = try await service.fetchTags()
        XCTAssertEqual(MockURLProtocol.captured.first?.headers["x-api-key"], "secret-key")
        XCTAssertEqual(MockURLProtocol.captured.first?.path, "/api/tags")
    }

    /// The generated client doesn't throw for a non-2xx reply; the service has to.
    func testARejectedRequestThrowsWithTheServersMessage() async {
        MockURLProtocol.handler = { _ in (500, #"{"message":"database exploded"}"#) }
        do {
            try await service.setFavorite(assetIds: ["a"], isFavorite: true)
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 500)
            XCTAssertTrue(message?.contains("database exploded") == true, "message was \(message ?? "nil")")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Album/tag changes report per-item failures inside an HTTP 200.
    func testAFailureInsideASuccessfulReplyIsStillAnError() async {
        MockURLProtocol.handler = { _ in (200, #"[{"id":"a","success":false,"error":"no_permission"}]"#) }
        do {
            try await service.removeAssets(["a"], fromAlbum: "album")
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTaggingSomethingAlreadyTaggedIsNotAnError() async throws {
        MockURLProtocol.handler = { _ in (200, #"[{"id":"a","success":false,"error":"duplicate"}]"#) }
        try await service.tagAssets(["a"], with: "tag")
    }

    func testClearingARatingSendsAnExplicitNull() async throws {
        MockURLProtocol.handler = { _ in (200, "[]") }
        try await service.clearRating(assetIds: ["a", "b"])
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/assets")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertTrue(json["rating"] is NSNull, "rating must be an explicit null, not left out")
        XCTAssertEqual(json["ids"] as? [String], ["a", "b"])
    }

    func testClearingARatingReportsAServerRefusal() async {
        MockURLProtocol.handler = { _ in (403, #"{"message":"nope"}"#) }
        do {
            try await service.clearRating(assetIds: ["a"])
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, _) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSharedLinkAddressUsesTheSlugWhenThereIsOne() throws {
        func link(key: String, slug: String?) throws -> Components.Schemas.SharedLinkResponseDto {
            let slugJSON = slug.map { "\"\($0)\"" } ?? "null"
            let json = """
            {"allowDownload":true,"allowUpload":false,"assets":[],"createdAt":"2024-01-01T00:00:00.000Z",
             "description":null,"expiresAt":null,"id":"id1","key":"\(key)","password":null,
             "showMetadata":true,"slug":\(slugJSON),"type":"INDIVIDUAL","userId":"u"}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Components.Schemas.SharedLinkResponseDto.self, from: Data(json.utf8))
        }
        XCTAssertEqual(service.sharedLinkURL(try link(key: "abc", slug: nil)).absoluteString, "https://immich.test/share/abc")
        XCTAssertEqual(service.sharedLinkURL(try link(key: "abc", slug: "holiday")).absoluteString, "https://immich.test/s/holiday")
    }

    func testPartnerPhotosAreReadOnly() {
        service.sharing.currentUserId = "me"
        let mine = AssetSummary(id: "1", isFavorite: false, isImage: true, ratio: 1, ownerId: "me")
        let theirs = AssetSummary(id: "2", isFavorite: false, isImage: true, ratio: 1, ownerId: "someone-else")
        let unknown = AssetSummary(id: "3", isFavorite: false, isImage: true, ratio: 1)
        XCTAssertTrue(service.isMine(mine))
        XCTAssertFalse(service.isMine(theirs))
        XCTAssertTrue(service.isMine(unknown), "unknown owner is treated as yours")
    }
}

final class LargeUploadTests: XCTestCase {
    private var service: ImmichService!
    private var saved: String?

    override func setUpWithError() throws {
        saved = UserDefaults.standard.string(forKey: ImmichService.directUploadKey)
        UserDefaults.standard.removeObject(forKey: ImmichService.directUploadKey)
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "k")
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: ImmichService.directUploadKey) }
        else { UserDefaults.standard.removeObject(forKey: ImmichService.directUploadKey) }
    }

    private let mb: Int64 = 1_048_576

    func testNormalUploadsGoToTheMainAddress() throws {
        XCTAssertEqual(try service.uploadTarget(forBytes: 5 * mb).absoluteString, "https://immich.test/api")
    }

    func testABigFileIsStillTriedUntilTheServerHasRefusedOne() throws {
        XCTAssertEqual(try service.uploadTarget(forBytes: 400 * mb).absoluteString, "https://immich.test/api")
    }

    func testOnceAFileWasRefusedBiggerOnesFailAtOnceWithAHelpfulMessage() {
        service.sharing.rejectedUploadBytes = 120 * mb
        XCTAssertNoThrow(try service.uploadTarget(forBytes: 50 * mb))
        do {
            _ = try service.uploadTarget(forBytes: 150 * mb)
            XCTFail("expected a refusal")
        } catch ImmichServiceError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 413)
            XCTAssertTrue(message?.contains("Settings") == true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testABigFileGoesToTheDirectAddressWhenOneIsSet() throws {
        UserDefaults.standard.set("http://192.168.1.20:2283/", forKey: ImmichService.directUploadKey)
        XCTAssertEqual(try service.uploadTarget(forBytes: 300 * mb).absoluteString, "http://192.168.1.20:2283/api")
        // Small files still take the normal route.
        XCTAssertEqual(try service.uploadTarget(forBytes: 10 * mb).absoluteString, "https://immich.test/api")
        // …even when a bigger one was refused earlier.
        service.sharing.rejectedUploadBytes = 100 * mb
        XCTAssertEqual(try service.uploadTarget(forBytes: 300 * mb).absoluteString, "http://192.168.1.20:2283/api")
    }

    func testTheDirectAddressMayAlreadyEndInAPI() {
        UserDefaults.standard.set("https://direct.example.com/api", forKey: ImmichService.directUploadKey)
        XCTAssertEqual(ImmichService.directUploadBase?.absoluteString, "https://direct.example.com/api")
    }

    func testNonsenseAddressesAreIgnored() {
        for text in ["", "   ", "not a url", "192.168.1.20:2283"] {
            UserDefaults.standard.set(text, forKey: ImmichService.directUploadKey)
            XCTAssertNil(ImmichService.directUploadBase, "\"\(text)\"")
        }
    }
}

final class SessionAuthTests: XCTestCase {
    private var service: ImmichService!

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { _ in (200, "[]") }
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "the-api-key")
    }

    override func tearDown() { URLProtocol.unregisterClass(MockURLProtocol.self) }

    func testNormallyRequestsUseTheAPIKeyOnly() async throws {
        _ = try await service.fetchTags()
        let headers = try XCTUnwrap(MockURLProtocol.captured.first?.headers)
        XCTAssertEqual(headers["x-api-key"], "the-api-key")
        XCTAssertNil(headers["authorization"])
    }

    func testWhileTheLockedFolderIsOpenRequestsUseTheSessionOnly() async throws {
        service.sharing.sessionToken = "session-token"
        service.sharing.useSession = true
        _ = try await service.fetchTags()
        let headers = try XCTUnwrap(MockURLProtocol.captured.first?.headers)
        XCTAssertEqual(headers["authorization"], "Bearer session-token")
        XCTAssertNil(headers["x-api-key"], "sending both lets the server pick, so only one is sent")
    }

    func testASavedTokenIsNotUsedUntilTheFolderIsOpened() async throws {
        service.sharing.sessionToken = "session-token"
        service.sharing.useSession = false
        _ = try await service.fetchTags()
        XCTAssertEqual(MockURLProtocol.captured.first?.headers["x-api-key"], "the-api-key")
    }

    func testHandBuiltRequestsFollowTheSameRule() {
        var normal = URLRequest(url: URL(string: "https://immich.test/x")!)
        service.authorize(&normal)
        XCTAssertEqual(normal.value(forHTTPHeaderField: "x-api-key"), "the-api-key")
        XCTAssertNil(normal.value(forHTTPHeaderField: "Authorization"))

        service.sharing.sessionToken = "tok"
        service.sharing.useSession = true
        var session = URLRequest(url: URL(string: "https://immich.test/x")!)
        service.authorize(&session)
        XCTAssertEqual(session.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(session.value(forHTTPHeaderField: "x-api-key"))
    }

    func testLockedFilterAsksForLockedVisibility() {
        XCTAssertTrue(TimelineFilter.locked.isLocked)
        XCTAssertFalse(TimelineFilter.none.isLocked)
        XCTAssertEqual(TimelineFilter.locked.visibility, .locked)
        XCTAssertFalse(TimelineFilter.locked.collapsesStacks)
        XCTAssertFalse(TimelineFilter.locked.includesPartnerPhotos)
    }
}

final class ActivityAndStorageTests: XCTestCase {
    private var service: ImmichService!

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "k")
    }

    override func tearDown() { URLProtocol.unregisterClass(MockURLProtocol.self) }

    private let activityReply = """
    {"id":"act1","type":"comment","createdAt":"2024-01-01T00:00:00.000Z","assetId":null,"comment":"hi",
     "user":{"id":"u1","name":"Sam","email":"s@x.com","avatarColor":"primary","profileChangedAt":"2024-01-01T00:00:00.000Z","profileImagePath":""}}
    """

    func testALikeIsSentWithoutACommentAndACommentWithOne() async throws {
        MockURLProtocol.handler = { _ in (201, self.activityReply) }
        try await service.createActivity(albumId: "album", assetId: nil, comment: nil)
        try await service.createActivity(albumId: "album", assetId: "asset", comment: "nice")

        let like = try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.captured[0].body) as? [String: Any])
        XCTAssertEqual(like["type"] as? String, "like")
        XCTAssertNil(like["comment"])
        XCTAssertEqual(like["albumId"] as? String, "album")

        let comment = try XCTUnwrap(JSONSerialization.jsonObject(with: MockURLProtocol.captured[1].body) as? [String: Any])
        XCTAssertEqual(comment["type"] as? String, "comment")
        XCTAssertEqual(comment["comment"] as? String, "nice")
        XCTAssertEqual(comment["assetId"] as? String, "asset")
    }

    func testActivityFailuresAreReported() async {
        MockURLProtocol.handler = { _ in (400, #"{"message":"Activity is disabled"}"#) }
        do {
            try await service.createActivity(albumId: "album", assetId: nil, comment: "x")
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(message?.contains("disabled") == true)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStorageIsReadFromTheServer() async throws {
        MockURLProtocol.handler = { _ in
            (200, #"{"diskAvailable":"600 GiB","diskAvailableRaw":644245094400,"diskSize":"1 TiB","diskSizeRaw":1099511627776,"diskUsagePercentage":45.5,"diskUse":"424 GiB","diskUseRaw":455266533376}"#)
        }
        let info = try await service.fetchStorage()
        XCTAssertEqual(info.used, "424 GiB")
        XCTAssertEqual(info.total, "1 TiB")
        XCTAssertEqual(info.fraction, 0.455, accuracy: 0.0001)
    }
}
