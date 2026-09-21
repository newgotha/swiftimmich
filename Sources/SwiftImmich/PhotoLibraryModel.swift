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
            errorMessage = "Couldn't load your library.\n\(FriendlyError.message(for: error))"
        }
    }

    func loadAssets(for timeBucket: String) async {
        guard assetsByBucket[timeBucket] == nil else { return }
        if let assets = await fetchBucket(timeBucket) { assetsByBucket[timeBucket] = assets }
    }

    /// Fetches one month's photos without storing them, falling back to the saved copy when
    /// the server can't be reached. Nil when nothing could be loaded.
    /// Assigning a @Published property redraws the grid even when the value is unchanged.
    private func clearError() { if errorMessage != nil { errorMessage = nil } }

    private func fetchBucket(_ timeBucket: String) async -> [AssetSummary]? {
        do {
            let assets = try await service.fetchAssets(inBucket: timeBucket, filter: filter)
            clearError()
            if !filter.isLocked { TimelineCache.save(assets, name: "bucket|\(cacheKey)|\(timeBucket)") }
            return assets
        } catch {
            if !Self.isCancellation(error), !filter.isLocked, let saved = TimelineCache.load([AssetSummary].self, name: "bucket|\(cacheKey)|\(timeBucket)") {
                return saved
            }
            guard Self.isCancellation(error) else {
                errorMessage = "Couldn't load photos for \(timeBucket).\n\(FriendlyError.message(for: error))"
                return nil
            }
            // Transient — often a Lazy container discarding an early measurement
            // pass. Retry once rather than leaving this month permanently blank.
            do {
                let assets = try await service.fetchAssets(inBucket: timeBucket, filter: filter)
                clearError()
                return assets
            } catch {
                if !Self.isCancellation(error) {
                    errorMessage = "Couldn't load photos for \(timeBucket).\n\(FriendlyError.message(for: error))"
                }
                return nil
            }
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

    /// How long to wait before showing what has arrived so far. Every redraw lays out every photo
    /// loaded, so the bigger the library gets the less often it's worth doing.
    static func flushInterval(loadedCount: Int) -> Double {
        0.4 + Double(loadedCount) / 40_000
    }

    /// Loads every bucket's assets up front, for the "All Photos"/"Years" views which
    /// need a single flat or year-grouped list rather than one lazily-loaded month at a time.
    func loadAllAssets() async {
        // A few months at a time rather than strictly one after another — a library
        // spanning years is hundreds of requests, and waiting on each in turn made
        // All Photos / Years take far longer than it needed to.
        //
        // Months are shown in batches, not one by one: each redraw lays out every photo loaded
        // so far, and doing that after each of 300 months made a big library crawl.
        let pending = buckets.map(\.timeBucket).filter { assetsByBucket[$0] == nil }
        var arrived: [String: [AssetSummary]] = [:]
        var loadedCount = assetsByBucket.values.reduce(0) { $0 + $1.count }
        var lastFlush = ContinuousClock.now

        func flush() {
            guard !arrived.isEmpty else { return }
            var merged = assetsByBucket
            for (bucket, assets) in arrived where merged[bucket] == nil { merged[bucket] = assets }
            assetsByBucket = merged
            arrived = [:]
            lastFlush = ContinuousClock.now
        }

        await withTaskGroup(of: (String, [AssetSummary]?).self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<6 {
                guard let next = iterator.next() else { break }
                group.addTask { (next, await self.fetchBucket(next)) }
            }
            while let (bucket, assets) = await group.next() {
                if let assets {
                    arrived[bucket] = assets
                    loadedCount += assets.count
                }
                let waited = lastFlush.duration(to: .now)
                let target = Duration.seconds(Self.flushInterval(loadedCount: loadedCount))
                if waited >= target { flush() }
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { (next, await self.fetchBucket(next)) }
            }
        }
        flush()
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
