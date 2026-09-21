import ImmichAPI
import XCTest
@testable import SwiftImmich

final class AssetMetadataTests: XCTestCase {
    private var service: ImmichService!

    struct Note: Codable, Equatable { var version: Int; var look: String; var amount: Double }

    override func setUpWithError() throws {
        AppLog.url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).log")
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        MockURLProtocol.captured = []
        service = try ImmichService(serverURLString: "https://immich.test", apiKey: "secret-key")
    }

    override func tearDown() { URLProtocol.unregisterClass(MockURLProtocol.self) }

    func testStoringANoteSendsTheKeyAndAnObject() async throws {
        MockURLProtocol.handler = { _ in (200, #"[{"key":"swiftimmich.edit.v1","value":{},"updatedAt":"2026-01-01T00:00:00.000Z"}]"#) }
        try await service.setAssetMetadata(Note(version: 1, look: "vivid", amount: 0.5), key: "swiftimmich.edit.v1", assetId: "a1")
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/assets/a1/metadata")
        XCTAssertEqual(request.headers["x-api-key"], "secret-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let item = try XCTUnwrap((body["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["key"] as? String, "swiftimmich.edit.v1")
        XCTAssertEqual((item["value"] as? [String: Any])?["look"] as? String, "vivid")
    }

    func testReadingANoteBack() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"key":"k","updatedAt":"2026-01-01T00:00:00.000Z","value":{"version":1,"look":"noir","amount":0.25}}"#) }
        let note = try await service.assetMetadata(Note.self, key: "k", assetId: "a1")
        XCTAssertEqual(note, Note(version: 1, look: "noir", amount: 0.25))
        XCTAssertEqual(MockURLProtocol.captured.first?.path, "/api/assets/a1/metadata/k")
    }

    func testAMissingNoteIsNilNotAnError() async throws {
        MockURLProtocol.handler = { _ in (404, #"{"message":"Not found"}"#) }
        let note = try await service.assetMetadata(Note.self, key: "nothing", assetId: "a1")
        XCTAssertNil(note)
    }

    func testTheServersOwnWayOfSayingNotFoundIsAlsoNil() async throws {
        MockURLProtocol.handler = { _ in (400, #"{"message":"Metadata with key \"k\" not found for asset with id \"a1\""}"#) }
        let note = try await service.assetMetadata(Note.self, key: "k", assetId: "a1")
        XCTAssertNil(note)
        MockURLProtocol.handler = { _ in (400, #"{"message":"something else is wrong"}"#) }
        do { _ = try await service.assetMetadata(Note.self, key: "k", assetId: "a1"); XCTFail("a real 400 is still an error") } catch {}
    }

    func testARefusalIsReported() async {
        MockURLProtocol.handler = { _ in (403, #"{"message":"Missing required permission: asset.update"}"#) }
        do {
            try await service.setAssetMetadata(Note(version: 1, look: "x", amount: 0), key: "k", assetId: "a1")
            XCTFail("expected a failure")
        } catch ImmichServiceError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(message?.contains("asset.update") == true)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAKeyWithDotsAndSymbolsIsSentSafely() async throws {
        MockURLProtocol.handler = { _ in (204, "") }
        try await service.deleteAssetMetadata(key: "swiftimmich edit/v1", assetId: "a1")
        let request = try XCTUnwrap(MockURLProtocol.captured.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertTrue(request.path.contains("swiftimmich"))
    }

    func testEverythingOnAPhotoCanBeListed() async throws {
        MockURLProtocol.handler = { _ in (200, #"[{"key":"a","value":{"n":1},"updatedAt":"t1"},{"key":"b","value":{"n":2},"updatedAt":"t2"}]"#) }
        let items = try await service.allAssetMetadata(assetId: "a1")
        XCTAssertEqual(items.map(\.key), ["a", "b"])
        XCTAssertTrue(items[0].json.contains("\"n\""))
    }

    func testMakingAStackAndChoosingItsCover() async throws {
        MockURLProtocol.handler = { request in
            let body = #"{"id":"stack-1","primaryAssetId":"copy","assets":[]}"#
            return request.method == "POST" ? (201, body) : (200, body)
        }
        let stack = try await service.createStackInfo(assetIds: ["copy", "original"])
        XCTAssertEqual(stack.id, "stack-1")
        XCTAssertEqual(stack.primaryAssetId, "copy")
        let updated = try await service.setStackPrimary(stackId: "stack-1", primaryAssetId: "copy")
        XCTAssertEqual(updated.primaryAssetId, "copy")
        let update = try XCTUnwrap(MockURLProtocol.captured.last)
        XCTAssertEqual(update.method, "PUT")
        XCTAssertEqual(update.path, "/api/stacks/stack-1")
    }
}

final class EditRecipeTests: XCTestCase {
    private func sample() -> EditRecipe {
        var adjustments = ImageAdjustments()
        adjustments.look = .noir; adjustments.lookIntensity = 0.7; adjustments.warmth = 0.2; adjustments.shadows = 0.4
        adjustments.vignette = 0.3; adjustments.straighten = -2.5; adjustments.brightness = 0.05
        adjustments.autoEnhance = .init(vibrance: 0.3, shadow: 0.2, intensity: 1.2)
        return EditRecipe(sourceId: "orig-1", rotation: 90, mirror: true, crop: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5), adjustments: adjustments)
    }

    func testARecipeSurvivesBeingStoredAndReadBack() throws {
        let recipe = sample()
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: data), recipe)
    }

    func testTheRecipeConvertsToAndFromAnExportRecipe() {
        let recipe = sample()
        let export = recipe.exportRecipe
        XCTAssertEqual(export.rotation, 90); XCTAssertTrue(export.mirror)
        XCTAssertEqual(export.cropFraction, CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5))
        XCTAssertEqual(export.adjustments, recipe.adjustments)
        XCTAssertEqual(EditRecipe(export, sourceId: "orig-1"), recipe)
    }

    func testMissingAndUnknownValuesAreTolerated() throws {
        let json = #"{"sourceId":"o","adjustments":{"look":"hologram","warmth":0.5,"somethingNew":7},"futureField":true}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.sourceId, "o")
        XCTAssertEqual(recipe.version, 1)
        XCTAssertEqual(recipe.rotation, 0)
        XCTAssertNil(recipe.crop)
        XCTAssertEqual(recipe.adjustments.look, .none, "a look this version doesn't know becomes none")
        XCTAssertEqual(recipe.adjustments.warmth, 0.5)
        XCTAssertEqual(recipe.adjustments.contrast, 1, "unmentioned values keep their neutral defaults")
    }

    func testARecipeWithoutASourceIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"rotation":90}"#.utf8)))
    }

    func testAnUntouchedRecipeIsEmpty() {
        XCTAssertTrue(EditRecipe(sourceId: "o").isEmpty)
        XCTAssertFalse(EditRecipe(sourceId: "o", rotation: 90).isEmpty)
        var straight = ImageAdjustments(); straight.straighten = 2
        XCTAssertFalse(EditRecipe(sourceId: "o", adjustments: straight).isEmpty)
    }

    func testTheNoteKeyIsVersioned() {
        XCTAssertEqual(EditRecipe.key, "swiftimmich.edit.v1")
    }
}
