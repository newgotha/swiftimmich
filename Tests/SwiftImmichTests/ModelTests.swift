import ImmichAPI
import XCTest
@testable import SwiftImmich

final class AssetSummaryTests: XCTestCase {
    func testTimelineColumnsBecomeSummaries() throws {
        let json = """
        {"id":["a","b"],"isFavorite":[true,false],"isImage":[true,false],"isTrashed":[false,false],
         "createdAt":["2024-01-01T00:00:00.000Z","2024-01-02T00:00:00.000Z"],
         "fileCreatedAt":["2024-01-01T10:00:00.000Z","2024-01-02T10:00:00.000Z"],
         "duration":[null,5000],"livePhotoVideoId":["clip",null],"localOffsetHours":[0,0],
         "ownerId":["me","partner"],"projectionType":[null,null],"ratio":[1.5,0.75],
         "thumbhash":[null,null],"visibility":["timeline","timeline"],
         "stack":[["stack1","3"],null]}
        """
        let dto = try JSONDecoder().decode(Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(json.utf8))
        let items = AssetSummary.makeSummaries(from: dto)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "a")
        XCTAssertTrue(items[0].isFavorite)
        XCTAssertEqual(items[0].stackId, "stack1")
        XCTAssertEqual(items[0].stackCount, 3)
        XCTAssertEqual(items[0].livePhotoVideoId, "clip")
        XCTAssertEqual(items[0].ownerId, "me")
        XCTAssertFalse(items[1].isImage)
        XCTAssertNil(items[1].stackId)
        XCTAssertEqual(items[1].ownerId, "partner")
        XCTAssertEqual(items[1].ratio, 0.75, accuracy: 0.001)
        XCTAssertNotNil(items[0].date)
    }

    func testASingleItemStackIsNotTreatedAsAStack() throws {
        let json = """
        {"id":["a"],"isFavorite":[false],"isImage":[true],"isTrashed":[false],
         "createdAt":["2024-01-01T00:00:00.000Z"],"fileCreatedAt":["2024-01-01T10:00:00.000Z"],
         "duration":[null],"livePhotoVideoId":[null],"localOffsetHours":[0],"ownerId":["me"],
         "projectionType":[null],"ratio":[1],"thumbhash":[null],"visibility":["timeline"],
         "stack":[["s","1"]]}
        """
        let dto = try JSONDecoder().decode(Components.Schemas.TimeBucketAssetResponseDto.self, from: Data(json.utf8))
        XCTAssertNil(AssetSummary.makeSummaries(from: dto)[0].stackId)
    }
}

final class ImportLedgerTests: XCTestCase {
    func testImportedItemsAreRemembered() {
        var ledger = ImportLedger()
        ledger.insert("photo-1")
        XCTAssertTrue(ledger.identifiers.contains("photo-1"))
        XCTAssertFalse(ledger.identifiers.contains("photo-2"))
    }

    func testAFailureIsRecordedAndClearedOnceImported() {
        var ledger = ImportLedger()
        ledger.recordFailure("photo-1", name: "IMG_1.HEIC", message: "timed out")
        ledger.recordFailure("photo-1", name: "IMG_1.HEIC", message: "timed out again")
        XCTAssertEqual(ledger.failed["photo-1"]?.attempts, 2)
        ledger.insert("photo-1")
        XCTAssertNil(ledger.failed["photo-1"])
    }
}

final class UploadClassificationTests: XCTestCase {
    func testTransientStatusesAreRetriedButRefusalsAreNot() {
        for status in [408, 429, 500, 502, 503, 504, 522] { XCTAssertTrue(CurlUploader.isTransient(status: status), "\(status)") }
        for status in [200, 201, 400, 401, 403, 404, 413] { XCTAssertFalse(CurlUploader.isTransient(status: status), "\(status)") }
    }

    func testNetworkHiccupsAreRetriedAndBadRequestsAreNot() {
        XCTAssertTrue(CurlUploader.Failure.transport(exitCode: 28, detail: "").isTransient)
        XCTAssertTrue(CurlUploader.Failure.transport(exitCode: 7, detail: "").isTransient)
        XCTAssertFalse(CurlUploader.Failure.transport(exitCode: 3, detail: "").isTransient)
        XCTAssertFalse(CurlUploader.Failure.couldNotStart("x").isTransient)
    }
}

final class TimeZoneParsingTests: XCTestCase {
    func testIANANames() {
        XCTAssertEqual(MetadataEditor.timeZone(from: "Australia/Sydney")?.identifier, "Australia/Sydney")
    }

    func testUTCOffsets() {
        XCTAssertEqual(MetadataEditor.timeZone(from: "UTC+10:00")?.secondsFromGMT(), 36000)
        XCTAssertEqual(MetadataEditor.timeZone(from: "UTC-5")?.secondsFromGMT(), -18000)
        XCTAssertEqual(MetadataEditor.timeZone(from: "UTC+5:30")?.secondsFromGMT(), 19800)
    }

    func testMissingOrNonsenseGivesNil() {
        XCTAssertNil(MetadataEditor.timeZone(from: nil))
        XCTAssertNil(MetadataEditor.timeZone(from: ""))
        XCTAssertNil(MetadataEditor.timeZone(from: "not a zone"))
    }
}

@MainActor
final class AlbumMembershipTests: XCTestCase {
    func testAddRemoveAndRename() {
        let membership = AlbumMembership()
        let holiday = AlbumMembership.AlbumRef(id: "1", name: "Holiday")
        membership.add(["a", "b"], to: holiday)
        XCTAssertEqual(membership.albums(for: "a").map(\.name), ["Holiday"])

        membership.rename(albumId: "1", to: "Trip")
        XCTAssertEqual(membership.albums(for: "b").map(\.name), ["Trip"])

        membership.remove(["a"], fromAlbum: "1")
        XCTAssertTrue(membership.albums(for: "a").isEmpty)
        XCTAssertEqual(membership.albums(for: "b").count, 1)
    }

    func testTheCurrentAlbumIsHiddenFromItsOwnBadges() {
        let membership = AlbumMembership()
        membership.add(["a"], to: .init(id: "1", name: "One"))
        membership.add(["a"], to: .init(id: "2", name: "Two"))
        XCTAssertEqual(membership.albums(for: "a", excluding: "1").map(\.name), ["Two"])
    }

    func testAddingTwiceDoesNotDuplicate() {
        let membership = AlbumMembership()
        let album = AlbumMembership.AlbumRef(id: "1", name: "One")
        membership.add(["a"], to: album)
        membership.add(["a"], to: album)
        XCTAssertEqual(membership.albums(for: "a").count, 1)
    }
}

final class DiskCacheTests: XCTestCase {
    func testStoredImagesComeBackAndCanBeRemoved() throws {
        let key = "test-\(UUID().uuidString)"
        DiskImageCache.write(key, data: Data([1, 2, 3]))
        guard let saved = DiskImageCache.read(key) else { throw XCTSkip("disk too full for the cache to save") }
        XCTAssertEqual(saved.data, Data([1, 2, 3]))
        XCTAssertTrue(saved.isFresh)
        DiskImageCache.remove(key)
        XCTAssertNil(DiskImageCache.read(key))
    }

    func testOldEntriesAreReportedStale() throws {
        let key = "test-\(UUID().uuidString)"
        DiskImageCache.write(key, data: Data([9]))
        guard DiskImageCache.read(key) != nil else { throw XCTSkip("disk too full for the cache to save") }
        defer { DiskImageCache.remove(key) }
        let files = try FileManager.default.contentsOfDirectory(at: DiskImageCache.directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let target = try XCTUnwrap(files.first { (try? Data(contentsOf: $0)) == Data([9]) })
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: target.path)
        XCTAssertEqual(DiskImageCache.read(key)?.isFresh, false)
    }
}

final class AppLogTests: XCTestCase {
    func testServerErrorsAreDescribedReadably() {
        let text = AppLog.describe(ImmichServiceError.requestFailed(statusCode: 403, message: "forbidden"))
        XCTAssertTrue(text.contains("403") && text.contains("forbidden"))
    }
}

final class SidebarOrderTests: XCTestCase {
    func testNothingSavedGivesTheDefaultOrder() {
        XCTAssertEqual(SidebarBlock.order(from: ""), SidebarBlock.defaultOrder)
    }

    func testAlbumsSitUnderPeopleByDefault() {
        let order = SidebarBlock.defaultOrder
        XCTAssertEqual(order.firstIndex(of: .albums), order.firstIndex(of: .people)! + 1)
    }

    func testASavedOrderIsRespected() {
        // A full order, as the app always saves it, comes back unchanged.
        let custom: [SidebarBlock] = [.tags, .albums, .library] + SidebarBlock.allCases.filter { ![.tags, .albums, .library].contains($0) }
        XCTAssertEqual(SidebarBlock.order(from: SidebarBlock.encode(custom)), custom)
    }

    func testAPartialSavedOrderKeepsItsRelativeOrderAndGainsTheRest() {
        let order = SidebarBlock.order(from: SidebarBlock.encode([.tags, .albums, .library]))
        XCTAssertLessThan(order.firstIndex(of: .tags)!, order.firstIndex(of: .albums)!)
        XCTAssertLessThan(order.firstIndex(of: .albums)!, order.firstIndex(of: .library)!)
        XCTAssertEqual(Set(order), Set(SidebarBlock.allCases), "everything missing is added back")
        XCTAssertEqual(order.count, SidebarBlock.allCases.count)
    }

    func testUnknownAndRepeatedEntriesAreIgnored() {
        let order = SidebarBlock.order(from: "library,bogus,library,people")
        XCTAssertLessThan(order.firstIndex(of: .library)!, order.firstIndex(of: .people)!)
        XCTAssertEqual(order.filter { $0 == .library }.count, 1)
        XCTAssertEqual(order.count, SidebarBlock.allCases.count)
    }

    func testANewItemLandsAfterItsDefaultNeighbour() {
        // An order saved before the tools group existed: it should appear right after the item
        // that precedes it by default.
        let defaults = SidebarBlock.defaultOrder
        let neighbour = defaults[defaults.firstIndex(of: .manage)! - 1]
        let old = defaults.filter { $0 != .manage }
        let order = SidebarBlock.order(from: SidebarBlock.encode(old))
        XCTAssertEqual(order.firstIndex(of: .manage), order.firstIndex(of: neighbour)! + 1)
    }

    func testOldSavedOrdersWithTheMovedPagesStillLoad() {
        // Orders saved when these pages were top-level rows: they're ignored, not fatal.
        let order = SidebarBlock.order(from: "library,duplicates,storage,sharing,importPhotos,backup,people")
        XCTAssertEqual(order.count, SidebarBlock.allCases.count)
        XCTAssertLessThan(order.firstIndex(of: .library)!, order.firstIndex(of: .people)!)
    }

    func testEveryPageBlockOpensItsPage() {
        for block in SidebarBlock.allCases {
            if let section = block.section { XCTAssertEqual(section.rawValue, block.rawValue) }
        }
    }
}

final class AlbumSeenTests: XCTestCase {
    func testCountsSurviveEncoding() {
        let json = AlbumSeen.save(["a": 3, "b": 0])
        XCTAssertEqual(AlbumSeen.load(json), ["a": 3, "b": 0])
        XCTAssertEqual(AlbumSeen.load(""), [:])
        XCTAssertEqual(AlbumSeen.load("garbage"), [:])
    }
}

final class BackupCheckTests: XCTestCase {
    private func local(_ id: String, _ name: String, _ date: Date?) -> BackupCheckModel.LocalItem {
        .init(id: id, name: name, date: date, isVideo: false)
    }

    private let taken = Date(timeIntervalSince1970: 1_700_000_000)

    func testAPhotoWithTheSameNameAndTimeIsOnTheServer() {
        let missing = BackupCheckModel.findMissing(
            local: [local("1", "IMG_1.HEIC", taken)],
            server: [.init(name: "IMG_1.HEIC", date: taken.addingTimeInterval(1))]
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testNamesAreComparedIgnoringCase() {
        let missing = BackupCheckModel.findMissing(
            local: [local("1", "IMG_1.HEIC", taken)],
            server: [.init(name: "img_1.heic", date: taken)]
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testAnotherPhotoWithTheSameNameAtADifferentTimeDoesNotCount() {
        // Cameras restart their numbering, so IMG_1234 can be two different photos.
        let missing = BackupCheckModel.findMissing(
            local: [local("1", "IMG_1.HEIC", taken)],
            server: [.init(name: "IMG_1.HEIC", date: taken.addingTimeInterval(86_400 * 400))]
        )
        XCTAssertEqual(missing.map(\.id), ["1"])
    }

    func testAPhotoNotOnTheServerIsMissing() {
        let missing = BackupCheckModel.findMissing(
            local: [local("1", "IMG_1.HEIC", taken), local("2", "IMG_2.HEIC", taken)],
            server: [.init(name: "IMG_1.HEIC", date: taken)]
        )
        XCTAssertEqual(missing.map(\.id), ["2"])
    }

    func testANamedMatchWithNoDateIsGivenTheBenefitOfTheDoubt() {
        let missing = BackupCheckModel.findMissing(
            local: [local("1", "IMG_1.HEIC", nil)],
            server: [.init(name: "IMG_1.HEIC", date: taken)]
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testAnEmptyServerMeansEverythingIsMissing() {
        let missing = BackupCheckModel.findMissing(local: [local("1", "a", taken), local("2", "b", taken)], server: [])
        XCTAssertEqual(missing.count, 2)
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(AppVersion("1.9")!, AppVersion("1.10")!)
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.0.1")!)
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("v2.1.0")!, AppVersion("2.1.0")!)
    }

    func testPreReleaseLabelsAreIgnoredAndJunkIsRejected() {
        XCTAssertEqual(AppVersion("1.2.0-beta.1")!, AppVersion("1.2.0")!)
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x"))
    }

    private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),"body":"Fixes and polish.",
         "html_url":"https://github.com/newgotha/swiftimmich/releases/tag/\(tag)",
         "assets":[
           {"name":"SHA256SUMS.txt","browser_download_url":"https://example.com/sums"},
           {"name":"SwiftImmich-1.2.0.zip","browser_download_url":"https://example.com/app.zip"},
           {"name":"SwiftImmich-1.2.0.dmg","browser_download_url":"https://example.com/app.dmg"}]}
        """.utf8)
    }

    func testAReleaseIsReadWithItsDiskImage() throws {
        let release = try XCTUnwrap(UpdateChecker.parse(releaseJSON(tag: "v1.2.0")))
        XCTAssertEqual(release.version, AppVersion("1.2.0"))
        XCTAssertEqual(release.notes, "Fixes and polish.")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.com/app.dmg", "the dmg is preferred over the zip")
        XCTAssertTrue(release.pageURL.absoluteString.hasSuffix("v1.2.0"))
    }

    func testDraftsAndPreReleasesAreNeverOffered() {
        XCTAssertNil(UpdateChecker.parse(releaseJSON(tag: "v1.2.0", draft: true)))
        XCTAssertNil(UpdateChecker.parse(releaseJSON(tag: "v1.2.0", prerelease: true)))
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parse(releaseJSON(tag: "nightly")))
    }

    func testWithoutADiskImageTheZipIsUsed() throws {
        let json = Data("""
        {"tag_name":"v2.0","html_url":"https://github.com/x/y/releases/tag/v2.0",
         "assets":[{"name":"App.zip","browser_download_url":"https://example.com/a.zip"}]}
        """.utf8)
        XCTAssertEqual(UpdateChecker.parse(json)?.downloadURL?.absoluteString, "https://example.com/a.zip")
    }
}
