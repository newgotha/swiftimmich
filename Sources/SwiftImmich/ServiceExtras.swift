import Foundation
import ImmichAPI

/// Album activity (comments and likes), server storage, and the "on this day" lookup.
extension ImmichService {
    typealias Activity = Components.Schemas.ActivityResponseDto

    // MARK: - Activity

    func fetchActivities(albumId: String, assetId: String?) async throws -> [Activity] {
        let response = try await client.getActivities(query: .init(
            albumId: albumId,
            assetId: assetId,
            level: assetId == nil ? .album : .asset
        ))
        return try response.ok.body.json
    }

    /// Adds a comment, or a like when `comment` is nil.
    @discardableResult
    func createActivity(albumId: String, assetId: String?, comment: String?) async throws -> Activity {
        let response = try await client.createActivity(body: .json(.init(
            albumId: albumId,
            assetId: assetId,
            comment: comment,
            _type: comment == nil ? .like : .comment
        )))
        switch response {
        case .created(let created): return try created.body.json
        case .undocumented(let statusCode, let payload): throw await Self.failure(statusCode, payload)
        }
    }

    func deleteActivity(id: String) async throws {
        let response = try await client.deleteActivity(.init(path: .init(id: id)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func activityCounts(albumId: String, assetId: String?) async throws -> (comments: Int, likes: Int) {
        let response = try await client.getActivityStatistics(query: .init(albumId: albumId, assetId: assetId))
        let stats = try response.ok.body.json
        return (stats.comments, stats.likes)
    }

    // MARK: - Storage

    struct StorageInfo {
        let used: String
        let total: String
        let available: String
        let fraction: Double
    }

    func fetchStorage() async throws -> StorageInfo {
        let response = try await client.getStorage()
        let storage = try response.ok.body.json
        return StorageInfo(
            used: storage.diskUse, total: storage.diskSize, available: storage.diskAvailable,
            fraction: storage.diskUsagePercentage / 100
        )
    }

    struct LibraryUsage {
        let photos: Int
        let videos: Int
        let usagePhotos: Int64
        let usageVideos: Int64
    }

    /// Server-wide totals. Only administrators may ask; anyone else gets an error.
    func fetchLibraryUsage() async throws -> LibraryUsage {
        let response = try await client.getServerStatistics()
        let stats = try response.ok.body.json
        return LibraryUsage(
            photos: stats.photos, videos: stats.videos,
            usagePhotos: Int64(stats.usagePhotos), usageVideos: Int64(stats.usageVideos)
        )
    }

    struct LargeItem: Identifiable, Hashable {
        let asset: AssetSummary
        let name: String
        let bytes: Int64
        var id: String { asset.id }
    }

    /// Walks every photo or video the server holds (a page at a time, so the caller can show
    /// progress) and reports each page's items with their sizes. `onPage` receives the running
    /// count of items looked at.
    @discardableResult
    func scanSizes(
        videos: Bool,
        onPage: @Sendable ([LargeItem], Int) -> Void
    ) async throws -> Int {
        var page = 1
        var scanned = 0
        while true {
            try Task.checkCancellation()
            let response = try await client.searchAssets(body: .json(.init(
                page: page, size: 1000, _type: videos ? .VIDEO : .IMAGE, withExif: true
            )))
            let result = try response.ok.body.json.assets
            scanned += result.items.count
            let items = result.items.compactMap { dto -> LargeItem? in
                guard let bytes = dto.exifInfo?.fileSizeInByte, bytes > 0 else { return nil }
                return LargeItem(asset: AssetSummary.makeSummaries(from: [dto])[0], name: dto.originalFileName, bytes: Int64(bytes))
            }
            onPage(items, scanned)
            guard let next = result.nextPage, let nextPage = Int(next) else { return scanned }
            page = nextPage
        }
    }

    // MARK: - Backup check

    struct ServerFile {
        let name: String
        let date: Date
    }

    /// Every file name and capture time the server holds, for comparing with the Photos library.
    func scanServerFiles(onPage: @Sendable (Int) -> Void) async throws -> [ServerFile] {
        var files: [ServerFile] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let response = try await client.searchAssets(body: .json(.init(page: page, size: 1000)))
            let result = try response.ok.body.json.assets
            files += result.items.map { ServerFile(name: $0.originalFileName, date: $0.fileCreatedAt) }
            onPage(files.count)
            guard let next = result.nextPage, let nextPage = Int(next) else { return files }
            page = nextPage
        }
    }

    // MARK: - On this day

    /// Photos taken on today's date in earlier years, newest year first, found from the
    /// timeline rather than waiting for the server to generate memories.
    func photosOnThisDay(now: Date = Date()) async throws -> [(year: Int, assets: [AssetSummary])] {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year, let month = today.month, let day = today.day else { return [] }

        let buckets = try await fetchTimeBuckets(filter: .none)
        // Buckets are labelled like "2021-09-01T00:00:00.000Z".
        let wanted = buckets.filter { bucket in
            let parts = bucket.timeBucket.prefix(10).split(separator: "-")
            guard parts.count == 3, let year = Int(parts[0]), let bucketMonth = Int(parts[1]) else { return false }
            return bucketMonth == month && year < thisYear
        }

        var found: [Int: [AssetSummary]] = [:]
        try await withThrowingTaskGroup(of: (Int, [AssetSummary]).self) { group in
            var iterator = wanted.makeIterator()
            func add(_ bucket: Components.Schemas.TimeBucketsResponseDto) {
                group.addTask {
                    let year = Int(bucket.timeBucket.prefix(4)) ?? 0
                    let assets = try await self.fetchAssets(inBucket: bucket.timeBucket, filter: .none)
                    let matches = assets.filter { asset in
                        guard let date = asset.date else { return false }
                        return calendar.component(.day, from: date) == day
                    }
                    return (year, matches)
                }
            }
            for _ in 0..<6 { if let next = iterator.next() { add(next) } }
            while let (year, matches) = try await group.next() {
                if !matches.isEmpty { found[year, default: []] += matches }
                if let next = iterator.next() { add(next) }
            }
        }
        return found.keys.sorted(by: >).map { (year: $0, assets: found[$0] ?? []) }
    }
}
