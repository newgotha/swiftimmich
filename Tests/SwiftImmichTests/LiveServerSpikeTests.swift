import AppKit
import CryptoKit
import ImmichAPI
import XCTest
@testable import SwiftImmich

/// Probes a REAL Immich server, so it only runs when `IMMICH_LIVE_SPIKE=1` is set. It uploads two tiny
/// generated images, tries the per-photo notes and stacking on them, then unstacks and trashes both.
/// It reads the server address and API key the installed app has saved, and never touches other photos.
final class LiveServerSpikeTests: XCTestCase {
    struct Note: Codable, Equatable { var version = 1; var look = "vivid"; var strength = 0.6 }
    struct Blob: Codable { var padding: String }

    private func tinyJPEG(_ shade: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        // Random blocks, so every run makes a picture the server hasn't seen (it spots repeats by checksum).
        for _ in 0..<12 {
            context.setFillColor(CGColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1))
            context.fill(CGRect(x: Int.random(in: 0..<56), y: Int.random(in: 0..<40), width: 8, height: 8))
        }
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }

    private func upload(_ service: ImmichService, name: String, shade: CGFloat) async throws -> String {
        let data = tinyJPEG(shade)
        let checksum = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        switch try await service.uploadAsset(data: data, filename: name, createdAt: Date(), modifiedAt: Date(), checksum: checksum) {
        case .created(let id), .duplicate(let id): return id
        }
    }

    func testProbeTheRealServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IMMICH_LIVE_SPIKE"] == "1", "set IMMICH_LIVE_SPIKE=1 to probe the real server")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dev.local.swiftimmich"))
        let address = try XCTUnwrap(defaults.string(forKey: "immichServerURL"))
        let key = try XCTUnwrap(APIKeyStore.load(), "no saved API key")
        let service = try ImmichService(serverURLString: address, apiKey: key)
        await service.refreshSharingState()

        let stamp = Int(Date().timeIntervalSince1970)
        let originalId = try await upload(service, name: "swiftimmich-spike-\(stamp)-original.jpg", shade: 0.25)
        let copyId = try await upload(service, name: "swiftimmich-spike-\(stamp)-copy.jpg", shade: 0.75)
        var stackId: String?
        print("SPIKE uploaded original=\(originalId) copy=\(copyId)")

        do {
            // 1. Notes on a photo
            let noteKey = "swiftimmich.edit.v1"
            try await service.setAssetMetadata(Note(), key: noteKey, assetId: copyId)
            let back = try await service.assetMetadata(Note.self, key: noteKey, assetId: copyId)
            print("SPIKE note round trip: \(String(describing: back))")
            XCTAssertEqual(back, Note())
            let missing = try await service.assetMetadata(Note.self, key: "swiftimmich.nothing", assetId: copyId)
            print("SPIKE missing key reads as: \(String(describing: missing))")
            let all = try await service.allAssetMetadata(assetId: copyId)
            print("SPIKE all notes on the copy: \(all.map { "\($0.key)=\($0.json)" })")
            try await service.setAssetMetadata(Note(look: "noir", strength: 1), key: noteKey, assetId: copyId)
            print("SPIKE overwrite gives: \(String(describing: try await service.assetMetadata(Note.self, key: noteKey, assetId: copyId)))")

            // How big a note is accepted?
            for kb in [2, 20, 200, 1000] {
                do {
                    try await service.setAssetMetadata(Blob(padding: String(repeating: "x", count: kb * 1024)), key: "swiftimmich.size-test", assetId: copyId)
                    print("SPIKE a \(kb) KB note: accepted")
                } catch {
                    print("SPIKE a \(kb) KB note: refused (\(AppLog.describe(error)))")
                }
            }
            try? await service.deleteAssetMetadata(key: "swiftimmich.size-test", assetId: copyId)

            // 2. Stacking: which photo becomes the cover?
            let stack = try await service.createStackInfo(assetIds: [copyId, originalId])
            stackId = stack.id
            print("SPIKE stack made with [copy, original]: primary is \(stack.primaryAssetId == copyId ? "the COPY" : "the ORIGINAL")")
            if stack.primaryAssetId != copyId {
                let changed = try await service.setStackPrimary(stackId: stack.id, primaryAssetId: copyId)
                print("SPIKE after choosing the copy: primary is \(changed.primaryAssetId == copyId ? "the COPY" : "the ORIGINAL")")
            }

            // 3. What the timeline shows now
            let buckets = try await service.fetchTimeBuckets(filter: .none)
            if let first = buckets.first {
                let items = try await service.fetchAssets(inBucket: first.timeBucket, filter: .none)
                print("SPIKE timeline shows copy: \(items.contains { $0.id == copyId }), original: \(items.contains { $0.id == originalId }), copy's stack size: \(items.first { $0.id == copyId }?.stackCount ?? 0)")
            }
            let info = try await service.fetchAssetInfo(assetId: originalId)
            print("SPIKE original's own info says stacked: \(info.stack != nil)")

            // 4. Do notes stay put after stacking?
            print("SPIKE note after stacking: \(String(describing: try await service.assetMetadata(Note.self, key: noteKey, assetId: copyId)))")
        } catch {
            XCTFail("probe failed: \(AppLog.describe(error))")
        }

        // Clean up: dissolve the stack, put both test photos in the trash.
        if let stackId { try? await service.deleteStacks(ids: [stackId]) }
        try await service.trashAssets([originalId, copyId])
        print("SPIKE cleaned up: stack removed, both test photos moved to the trash")
    }

    /// Runs the real publish logic on the server: a first edit, a re-edit that replaces the copy, and an
    /// original that was already in a stack with another photo.
    func testPublishingEditedCopiesOnTheRealServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IMMICH_LIVE_SPIKE"] == "1", "set IMMICH_LIVE_SPIKE=1 to probe the real server")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dev.local.swiftimmich"))
        let service = try ImmichService(serverURLString: try XCTUnwrap(defaults.string(forKey: "immichServerURL")), apiKey: try XCTUnwrap(APIKeyStore.load()))
        await service.refreshSharingState()
        let stamp = Int(Date().timeIntervalSince1970)
        var created: [String] = []
        var stacks: [String] = []
        func make(_ label: String, _ shade: CGFloat) async throws -> String {
            let id = try await upload(service, name: "swiftimmich-spike-\(stamp)-\(label).jpg", shade: shade)
            created.append(id)
            return id
        }
        func timeline() async throws -> [AssetSummary] {
            let buckets = try await service.fetchTimeBuckets(filter: .none)
            return try await service.fetchAssets(inBucket: try XCTUnwrap(buckets.first).timeBucket, filter: .none)
        }

        do {
            // A. A first edit of a plain photo.
            let original = try await make("original", 0.2)
            let copy1 = try await make("copy1", 0.5)
            let recipe1 = EditRecipe(sourceId: original, adjustments: { var a = ImageAdjustments(); a.look = .vivid; return a }())
            let stack1 = try await service.publishEditedCopy(newCopyId: copy1, originalId: original, replacing: nil, recipe: recipe1)
            stacks.append(stack1)
            var shown = try await timeline()
            XCTAssertTrue(shown.contains { $0.id == copy1 && $0.stackCount == 2 }, "A: the copy is the cover of a stack of two")
            XCTAssertFalse(shown.contains { $0.id == original }, "A: the original sits behind it")
            let read1 = try await service.assetMetadata(EditRecipe.self, key: EditRecipe.key, assetId: copy1)
            XCTAssertEqual(read1, recipe1)
            print("SPIKE A first edit: ok, recipe read back = \(read1 != nil)")

            // B. Editing again replaces the copy.
            let copy2 = try await make("copy2", 0.8)
            var adjustments2 = ImageAdjustments(); adjustments2.look = .noir
            let recipe2 = EditRecipe(sourceId: original, adjustments: adjustments2)
            let stack2 = try await service.publishEditedCopy(newCopyId: copy2, originalId: original, replacing: copy1, recipe: recipe2)
            stacks.append(stack2)
            shown = try await timeline()
            XCTAssertTrue(shown.contains { $0.id == copy2 && $0.stackCount == 2 }, "B: the new copy is the cover, still a stack of two")
            XCTAssertFalse(shown.contains { $0.id == copy1 }, "B: the old copy is gone from the library")
            let oldStillThere = try? await service.fetchAssetInfo(assetId: copy1)
            print("SPIKE B re-edit: ok; old copy trashed=\(oldStillThere?.isTrashed == true)")

            // C. An original that was already stacked with another photo keeps it.
            let burstA = try await make("burstA", 0.35)
            let burstB = try await make("burstB", 0.65)
            let burstStack = try await service.createStackInfo(assetIds: [burstA, burstB])
            stacks.append(burstStack.id)
            let copy3 = try await make("copy3", 0.9)
            let stack3 = try await service.publishEditedCopy(newCopyId: copy3, originalId: burstB, replacing: nil, recipe: EditRecipe(sourceId: burstB))
            stacks.append(stack3)
            shown = try await timeline()
            XCTAssertTrue(shown.contains { $0.id == copy3 && $0.stackCount == 3 }, "C: the copy joins the existing stack, now three photos")
            print("SPIKE C existing stack kept: ok (stack size \(shown.first { $0.id == copy3 }?.stackCount ?? 0))")

            // D. Removing an edit brings the original back on its own.
            let plain = try await make("plain", 0.15)
            let plainCopy = try await make("plainCopy", 0.55)
            let stack4 = try await service.publishEditedCopy(newCopyId: plainCopy, originalId: plain, replacing: nil, recipe: EditRecipe(sourceId: plain))
            stacks.append(stack4)
            try await service.discardEditedCopy(copyId: plainCopy)
            shown = try await timeline()
            XCTAssertTrue(shown.contains { $0.id == plain && $0.stackId == nil }, "D: the original is back, no longer stacked")
            XCTAssertFalse(shown.contains { $0.id == plainCopy }, "D: the copy is gone")
            print("SPIKE D remove edit: ok")
        } catch {
            XCTFail("probe failed: \(AppLog.describe(error))")
        }

        for id in stacks { try? await service.deleteStacks(ids: [id]) }
        try await service.trashAssets(created)
        print("SPIKE cleaned up \(created.count) test photos (moved to the trash)")
    }
}
