import Foundation
import ImmichAPI
import OpenAPIRuntime
import CryptoKit

/// A saved copy of what the server last said about the timeline (which months exist and
/// what's in each), so the grid can still be shown with no connection. Only used when
/// the server can't be reached; a reachable server always wins.
enum TimelineCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SwiftImmich/Timeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ name: String) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    static func save<T: Encodable & Sendable>(_ value: T, name: String) {
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: file(name), options: .atomic) }
        }
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published private(set) var buckets: [Components.Schemas.TimeBucketsResponseDto] = []
    @Published private(set) var assetsByBucket: [String: [AssetSummary]] = [:]
    @Published var errorMessage: String?
    @Published private(set) var isLoadingBuckets = false
    /// True when the server couldn't be reached and this is the last saved copy.
    @Published private(set) var isShowingSavedCopy = false

    private var cacheKey: String { "\(filter)|partners=\(service.sharing.includePartnerPhotos)" }

    let service: ImmichService
    let filter: TimelineFilter

    init(service: ImmichService, filter: TimelineFilter = .none) {
        self.service = service
        self.filter = filter
    }

    func loadBuckets() async {
        guard buckets.isEmpty else { return }
        isLoadingBuckets = true
        defer { isLoadingBuckets = false }
        do {
            buckets = try await service.fetchTimeBuckets(filter: filter)
            isShowingSavedCopy = false
            errorMessage = nil
            if !filter.isLocked { TimelineCache.save(buckets, name: "buckets|\(cacheKey)") }
        } catch {
            guard !Self.isCancellation(error) else { return }
            if !filter.isLocked, let saved = TimelineCache.load([Components.Schemas.TimeBucketsResponseDto].self, name: "buckets|\(cacheKey)"), !saved.isEmpty {
                buckets = saved
                isShowingSavedCopy = true
                errorMessage = nil
                return
            }
            errorMessage = "Couldn't load your library: \(error)"
        }
    }

    func loadAssets(for timeBucket: String) async {
        guard assetsByBucket[timeBucket] == nil else { return }
        do {
            let assets = try await service.fetchAssets(inBucket: timeBucket, filter: filter)
            assetsByBucket[timeBucket] = assets
            errorMessage = nil
            if !filter.isLocked { TimelineCache.save(assets, name: "bucket|\(cacheKey)|\(timeBucket)") }
        } catch {
            if !Self.isCancellation(error), !filter.isLocked, let saved = TimelineCache.load([AssetSummary].self, name: "bucket|\(cacheKey)|\(timeBucket)") {
                assetsByBucket[timeBucket] = saved
                return
            }
            guard !Self.isCancellation(error) else {
                // Transient — often a Lazy container discarding an early measurement
                // pass. Retry once rather than leaving this month permanently blank.
                await retryLoadAssets(for: timeBucket)
                return
            }
            errorMessage = "Couldn't load photos for \(timeBucket): \(error)"
        }
    }

    private func retryLoadAssets(for timeBucket: String) async {
        guard assetsByBucket[timeBucket] == nil else { return }
        do {
            assetsByBucket[timeBucket] = try await service.fetchAssets(inBucket: timeBucket, filter: filter)
            errorMessage = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = "Couldn't load photos for \(timeBucket): \(error)"
        }
    }

    /// Immich's generated client wraps a cancelled request in `ClientError`, so a plain
    /// `error is CancellationError` check never matches — the real cause is one level
    /// in, and can surface as either Swift's `CancellationError` or, when URLSession
    /// itself cancels the transport (e.g. a Lazy container discarding an in-flight
    /// request), an `NSURLErrorDomain` error with code `NSURLErrorCancelled` (-999).
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let clientError = error as? ClientError else { return false }
        if clientError.underlyingError is CancellationError { return true }
        let nsError = clientError.underlyingError as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Loads every bucket's assets up front, for the "All Photos"/"Years" views which
    /// need a single flat or year-grouped list rather than one lazily-loaded month at a time.
    func loadAllAssets() async {
        // A few months at a time rather than strictly one after another — a library
        // spanning years is hundreds of requests, and waiting on each in turn made
        // All Photos / Years take far longer than it needed to.
        let pending = buckets.map(\.timeBucket).filter { assetsByBucket[$0] == nil }
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<6 {
                guard let next = iterator.next() else { break }
                group.addTask { await self.loadAssets(for: next) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { await self.loadAssets(for: next) }
            }
        }
    }

    /// All currently-loaded assets, newest first, across every bucket — only complete
    /// once `loadAllAssets()` has finished.
    var allLoadedAssets: [AssetSummary] {
        buckets.flatMap { assetsByBucket[$0.timeBucket] ?? [] }
    }

    /// Reflects a favorite/unfavorite made elsewhere (viewer, right-click menu). On the
    /// Favorites page an unfavorited photo no longer belongs, so it leaves instead.
    func applyFavorite(_ change: FavoriteChange) {
        let ids = Set(change.ids)
        for (timeBucket, assets) in assetsByBucket where assets.contains(where: { ids.contains($0.id) }) {
            if filter == .favorites && !change.value {
                assetsByBucket[timeBucket] = assets.filter { !ids.contains($0.id) }
            } else {
                assetsByBucket[timeBucket] = assets.map { asset in
                    var updated = asset
                    if ids.contains(asset.id) { updated.isFavorite = change.value }
                    return updated
                }
            }
        }
    }

    func clear() {
        buckets = []
        assetsByBucket = [:]
        isShowingSavedCopy = false
    }

    /// Drops an asset from whichever bucket holds it, e.g. after deleting it in the
    /// viewer — scans every loaded bucket rather than requiring the caller to know which one.
    func removeAsset(id: String) {
        for (timeBucket, assets) in assetsByBucket where assets.contains(where: { $0.id == id }) {
            assetsByBucket[timeBucket] = assets.filter { $0.id != id }
        }
    }
}
