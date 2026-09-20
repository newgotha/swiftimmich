import ImmichAPI
import SwiftUI

/// Which albums each photo is in, for the album badge on grid thumbnails.
///
/// Immich has no "albums for these 500 thumbnails" call, and asking per photo would be
/// hundreds of requests, so this flips it around: list each album's photos once (the
/// timeline endpoint returns them as a compact list of ids) and invert that into a
/// photo -> albums map. It's then kept current locally whenever the app adds or
/// removes photos, and re-read when the app comes back to the front, so changes made
/// elsewhere (the web UI, another device) show up without a restart.
@MainActor
final class AlbumMembership: ObservableObject {
    struct AlbumRef: Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var byAsset: [String: [AlbumRef]] = [:]

    private var rebuildTask: Task<Void, Never>?
    private var lastRebuild = Date.distantPast

    /// `excluding` hides the album currently being viewed, where every photo is in it
    /// and a badge on all of them would just be noise.
    func albums(for assetId: String, excluding albumId: String? = nil) -> [AlbumRef] {
        (byAsset[assetId] ?? []).filter { $0.id != albumId }
    }

    /// Re-reads every album's contents. Cancels a rebuild already in flight.
    func rebuild(albums: [Components.Schemas.AlbumResponseDto], service: ImmichService) {
        rebuildTask?.cancel()
        let previous = byAsset
        rebuildTask = Task {
            var result: [String: [AlbumRef]] = [:]
            var failedAlbumIds: Set<String> = []

            await withTaskGroup(of: (AlbumRef, [String]?).self) { group in
                for album in albums where album.assetCount > 0 {
                    let ref = AlbumRef(id: album.id, name: album.albumName)
                    group.addTask { (ref, try? await Self.assetIds(in: ref, service: service)) }
                }
                for await (ref, ids) in group {
                    guard let ids else { failedAlbumIds.insert(ref.id); continue }
                    for id in ids { result[id, default: []].append(ref) }
                }
            }
            guard !Task.isCancelled else { return }

            // An album that couldn't be read this time keeps what it had, rather than
            // its badges vanishing because of one failed request.
            if !failedAlbumIds.isEmpty {
                for (assetId, refs) in previous {
                    for ref in refs where failedAlbumIds.contains(ref.id) {
                        result[assetId, default: []].append(ref)
                    }
                }
            }
            byAsset = result.mapValues { $0.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
            lastRebuild = Date()
        }
    }

    /// For "the app just came to the front": cheap to call, only does work if the last
    /// read is a couple of minutes old.
    func rebuildIfStale(albums: [Components.Schemas.AlbumResponseDto], service: ImmichService) {
        guard Date().timeIntervalSince(lastRebuild) > 120 else { return }
        rebuild(albums: albums, service: service)
    }

    func add(_ assetIds: [String], to album: AlbumRef) {
        var updated = byAsset
        for id in assetIds {
            var refs = updated[id] ?? []
            guard !refs.contains(album) else { continue }
            refs.append(album)
            updated[id] = refs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        byAsset = updated
    }

    func rename(albumId: String, to name: String) {
        byAsset = byAsset.mapValues { refs in
            refs.map { $0.id == albumId ? AlbumRef(id: albumId, name: name) : $0 }
        }
    }

    func remove(_ assetIds: [String], fromAlbum albumId: String) {
        var updated = byAsset
        for id in assetIds {
            guard let refs = updated[id] else { continue }
            let kept = refs.filter { $0.id != albumId }
            updated[id] = kept.isEmpty ? nil : kept
        }
        byAsset = updated
    }

    private nonisolated static func assetIds(in album: AlbumRef, service: ImmichService) async throws -> [String] {
        let filter = TimelineFilter.album(id: album.id, name: album.name)
        var ids: [String] = []
        for bucket in try await service.fetchTimeBuckets(filter: filter) {
            try Task.checkCancellation()
            ids += try await service.fetchAssets(inBucket: bucket.timeBucket, filter: filter).map(\.id)
        }
        return ids
    }
}
