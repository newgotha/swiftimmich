import AppKit
import CryptoKit
import Foundation

/// Posted (with the asset id as `object`) after a native edit (rotate/mirror/crop) is
/// saved, so any already-loaded `AssetThumbnailView` for that asset — e.g. sitting in
/// a grid opened before the edit — knows to drop its own cached image and refetch.
/// `AssetThumbnailView`'s `.task(id: asset.id)` only reruns when the asset's *id*
/// changes, which an edit never does, so without this a grid cell that had already
/// loaded kept showing the pre-edit thumbnail for the rest of the session even though
/// `ThumbnailLoader`'s own cache was already invalidated.
extension Notification.Name {
    static let assetEdited = Notification.Name("dev.local.swiftimmich.assetEdited")
}

/// Images kept on disk between launches (in ~/Library/Caches, which macOS may also
/// reclaim), so a grid comes back instantly after a restart and thumbnails you've
/// already seen still show with no connection.
///
/// Entries expire after two weeks and are then refetched — the server can change what
/// it renders (an edit made in the web app, say) without this app ever hearing about
/// it — but an expired copy is still used if the server can't be reached. The total is
/// capped (Settings), evicting the least recently used first.
enum DiskImageCache {
    /// Only reassigned by tests, so they don't write into the real cache.
    nonisolated(unsafe) static var directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SwiftImmich/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let maxAge: TimeInterval = 14 * 24 * 3600
    static let limitKey = "imageCacheLimitMB"

    static var limitBytes: Int {
        let megabytes = UserDefaults.standard.object(forKey: limitKey) as? Int ?? 1024
        return megabytes * 1_048_576
    }

    private static func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// The saved bytes and whether they're still within `maxAge`.
    static func read(_ key: String) -> (data: Data, isFresh: Bool)? {
        let file = url(for: key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return (data, Date().timeIntervalSince(modified) < maxAge)
    }

    /// Saving is skipped when the disk is nearly full — a cache should never be what
    /// finishes it off.
    static func write(_ key: String, data: Data) {
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? .max
        guard free > 2_000_000_000 else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    static func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
        TimelineCache.clear()
    }

    /// Deletes the oldest files until the cache is back under its limit.
    static func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        let limit = limitBytes
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit * 9 / 10 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

/// Lets a few downloads run at a time, and serves the most recent request first — those are the
/// photos on screen now, while older ones were probably scrolled past. Scrolling fast through a
/// big library otherwise starts hundreds of downloads at once, most of them for photos never seen.
actor FetchGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if let next = waiting.popLast() {
            next.resume()   // the slot passes straight to the newest waiter
        } else {
            running -= 1
        }
    }
}

/// Loads asset thumbnails over authenticated requests (SwiftUI's AsyncImage can't attach
/// the x-api-key header Immich requires) and caches them in memory and on disk.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Who is still waiting on each in-flight download. When they've all scrolled away before
    /// its turn comes, the download is skipped. Tracked per caller (not as a count) so a late
    /// cancellation can never make a later request look abandoned.
    private var waiters: [String: Set<UUID>] = [:]
    private let gate = FetchGate(limit: 8)
    private var writesSincePrune = 0
    /// Keys of images fetched with a Locked Folder session; never written to disk, and forgotten on lock.
    private var sensitiveKeys: Set<String> = []

    init() {
        // A big library would otherwise keep every thumbnail ever scrolled past in memory.
        cache.countLimit = 4000
        // Decoded thumbnails are far bigger than their files, so also cap by pixels held.
        cache.totalCostLimit = 300 * 1_048_576
        Task.detached(priority: .utility) { DiskImageCache.prune() }
    }

    func image(for assetId: String, request: URLRequest) async -> NSImage? {
        let key = assetId as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let waiter = UUID()
        waiters[assetId, default: []].insert(waiter)
        let task: Task<NSImage?, Never>
        if let existing = inFlight[assetId] {
            task = existing
        } else {
            let sensitive = request.value(forHTTPHeaderField: "Authorization") != nil
            task = Task<NSImage?, Never> {
                let saved = sensitive ? nil : await Task.detached(priority: .userInitiated) { DiskImageCache.read(assetId) }.value
                if let saved, saved.isFresh, let image = NSImage(data: saved.data) {
                    return image
                }
                await gate.acquire()
                defer { Task { await gate.release() } }
                // Everyone who asked has scrolled away while this waited its turn.
                if await self.nobodyWaiting(for: assetId) {
                    if let saved, let image = NSImage(data: saved.data) { return image }
                    return nil
                }
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                        if !sensitive {
                            DiskImageCache.write(assetId, data: data)
                            await self.noteWrite()
                        }
                        return image
                    }
                } catch {}
                // The server couldn't be reached: an out-of-date copy beats a blank tile.
                if let saved, let image = NSImage(data: saved.data) { return image }
                return nil
            }
            inFlight[assetId] = task
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.stopWaiting(waiter, for: assetId) }
        }
        inFlight[assetId] = nil
        stopWaiting(waiter, for: assetId)
        if let image {
            cache.setObject(image, forKey: key, cost: Self.cost(of: image))
            if request.value(forHTTPHeaderField: "Authorization") != nil { sensitiveKeys.insert(assetId) }
        }
        return image
    }

    private func nobodyWaiting(for assetId: String) -> Bool { waiters[assetId]?.isEmpty ?? true }
    private func stopWaiting(_ waiter: UUID, for assetId: String) {
        waiters[assetId]?.remove(waiter)
        if waiters[assetId]?.isEmpty == true { waiters[assetId] = nil }
    }

    /// Roughly the bytes the decoded image occupies.
    static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(rep.pixelsWide * rep.pixelsHigh * 4, 1)
    }

    /// Forgets everything fetched while the Locked Folder was open.
    func purgeSensitive() {
        for key in sensitiveKeys { cache.removeObject(forKey: key as NSString) }
        sensitiveKeys = []
    }

    private func noteWrite() {
        writesSincePrune += 1
        if writesSincePrune >= 300 {
            writesSincePrune = 0
            Task.detached(priority: .utility) { DiskImageCache.prune() }
        }
    }

    /// Drops both the grid-thumbnail and viewer-preview cache entries for an asset —
    /// needed after applying an edit, since Immich's crop/rotate/mirror are
    /// non-destructive but do change what the server renders for the same asset id.
    func invalidate(assetId: String) {
        cache.removeObject(forKey: assetId as NSString)
        cache.removeObject(forKey: "preview-\(assetId)" as NSString)
        DiskImageCache.remove(assetId)
        DiskImageCache.remove("preview-\(assetId)")
    }

    /// Seeds the cache directly with an already-known-correct image — e.g. one baked
    /// locally right after a save — instead of just invalidating and letting the next
    /// load refetch from the server. Immich regenerates a saved edit's actual
    /// thumbnail/preview files as a background job that can lag well behind the
    /// edit's own success response, so a refetch immediately after saving can still
    /// return the pre-edit render; this sidesteps that entirely, the same way this
    /// app's whole instant-local-preview design avoids waiting on it for the viewer.
    func seed(assetId: String, image: NSImage) {
        cache.setObject(image, forKey: assetId as NSString)
        cache.setObject(image, forKey: "preview-\(assetId)" as NSString)
        if let data = DiskImageCache.jpegData(from: image) {
            DiskImageCache.write(assetId, data: data)
            DiskImageCache.write("preview-\(assetId)", data: data)
        }
    }

    /// Forgets every cached image, in memory and on disk.
    func clearAll() {
        cache.removeAllObjects()
        DiskImageCache.clear()
    }
}
