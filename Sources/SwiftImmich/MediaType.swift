import Foundation
import ImmichAPI

/// The "Media Types" sidebar filters, modelled on Photos.app's.
///
/// Photos knows some of these from data Immich never stores — portrait mode, long
/// exposure, slo-mo, time-lapse, cinematic, spatial, and burst grouping have no
/// equivalent in Immich's metadata, so they're deliberately not offered rather than
/// shown as filters that would always come back empty or wrong. Where a type here has
/// to be inferred instead of read directly, `explanation` says how.
enum MediaType: String, CaseIterable, Identifiable, Hashable {
    case videos, selfies, livePhotos, panoramas, screenshots, screenRecordings, animated, raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: return "Videos"
        case .selfies: return "Selfies"
        case .livePhotos: return "Live Photos"
        case .panoramas: return "Panoramas"
        case .screenshots: return "Screenshots"
        case .screenRecordings: return "Screen Recordings"
        case .animated: return "Animated"
        case .raw: return "RAW"
        }
    }

    var icon: String {
        switch self {
        case .videos: return "video"
        case .selfies: return "person.crop.square"
        case .livePhotos: return "livephoto"
        case .panoramas: return "pano"
        case .screenshots: return "camera.viewfinder"
        case .screenRecordings: return "record.circle"
        case .animated: return "play.square.stack"
        case .raw: return "r.square.on.square"
        }
    }

    var explanation: String? {
        switch self {
        case .videos, .livePhotos: return nil
        case .selfies: return "Photos taken with a front-facing camera, recognised from the camera's lens name."
        case .panoramas: return "Photos at least 2.4 times wider (or taller) than they are high."
        case .screenshots: return "Files named “Screenshot”, plus PNG images that carry no camera information."
        case .screenRecordings: return "Videos named “Screen Recording” or “RPReplay”."
        case .animated: return "GIF files."
        case .raw: return "RAW files: DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2, PEF and SRW."
        }
    }

    fileprivate static let rawExtensions = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"]
    fileprivate static let panoramaAspect = 2.4
}

extension ImmichService {
    /// Photos with exactly this many stars, newest first.
    func ratedSnapshots(_ stars: Int) -> AsyncThrowingStream<[AssetSummary], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var found: [String: AssetSummary] = [:]
                    try await searchPages(rating: stars) { items in
                        for item in items { found[item.id] = item }
                        continuation.yield(found.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams growing snapshots of everything matching `type`, newest first — each
    /// element is the complete list so far, so the grid can fill in as pages arrive
    /// instead of showing nothing until a large library has been fully searched.
    func mediaTypeSnapshots(_ type: MediaType) -> AsyncThrowingStream<[AssetSummary], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var found: [String: AssetSummary] = [:]
                    func add(_ items: [AssetSummary]) {
                        for item in items { found[item.id] = item }
                        continuation.yield(found.values.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
                    }
                    try await collect(type, add: add)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func collect(_ type: MediaType, add: ([AssetSummary]) -> Void) async throws {
        switch type {
        case .videos:
            try await searchPages(type: .VIDEO, add: add)

        case .livePhotos:
            try await searchPages(isMotion: true, add: add)

        case .selfies:
            // iPhone lens names read like "iPhone 15 Pro front camera 2.69mm f/1.9".
            let lensModels = try await fetchLensModels().filter { $0.localizedCaseInsensitiveContains("front") }
            for lens in lensModels {
                try await searchPages(lensModel: lens, type: .IMAGE, add: add)
            }

        case .panoramas:
            // No server-side size filter exists, so scan the timeline (which carries
            // each item's aspect ratio) newest-first, one month at a time.
            for bucket in try await fetchTimeBuckets(filter: .none) {
                try Task.checkCancellation()
                let matches = try await fetchAssets(inBucket: bucket.timeBucket, filter: .none).filter {
                    $0.isImage && ($0.ratio >= MediaType.panoramaAspect || $0.ratio <= 1 / MediaType.panoramaAspect)
                }
                if !matches.isEmpty { add(matches) }
            }

        case .screenshots:
            try await searchPages(fileName: "screenshot", type: .IMAGE, add: add)
            try await searchPages(fileName: "screen shot", type: .IMAGE, add: add)
            // iPhone screenshots are named like any other photo (IMG_1234.PNG) — what
            // gives them away is being a PNG with no camera make recorded.
            try await searchPages(fileName: ".png", type: .IMAGE, withExif: true, keeping: { $0.exifInfo?.make == nil }, add: add)

        case .screenRecordings:
            for name in ["screen recording", "screenrecording", "rpreplay"] {
                try await searchPages(fileName: name, type: .VIDEO, add: add)
            }

        case .animated:
            try await searchPages(fileName: ".gif", type: .IMAGE, add: add)

        case .raw:
            for ext in MediaType.rawExtensions {
                try await searchPages(fileName: ".\(ext)", type: .IMAGE, add: add)
            }
        }
    }

    private func fetchLensModels() async throws -> [String] {
        let response = try await client.getSearchSuggestions(query: .init(_type: .camera_hyphen_lens_hyphen_model))
        return try response.ok.body.json
    }

    /// Walks every page of a metadata search. `.ok` throws for any non-200 response, so
    /// a rejected search surfaces as an error rather than as an empty result.
    private func searchPages(
        isMotion: Bool? = nil,
        lensModel: String? = nil,
        fileName: String? = nil,
        type: Components.Schemas.AssetTypeEnum? = nil,
        withExif: Bool = false,
        rating: Int? = nil,
        keeping: (Components.Schemas.AssetResponseDto) -> Bool = { _ in true },
        add: ([AssetSummary]) -> Void
    ) async throws {
        var page = 1
        while true {
            try Task.checkCancellation()
            let response = try await client.searchAssets(body: .json(.init(
                isMotion: isMotion,
                lensModel: lensModel,
                originalFileName: fileName,
                page: page,
                rating: rating,
                size: 1000,
                _type: type,
                withExif: withExif ? true : nil
            )))
            let result = try response.ok.body.json.assets
            let items = result.items.filter(keeping)
            if !items.isEmpty { add(AssetSummary.makeSummaries(from: items)) }
            guard let next = result.nextPage, let nextPage = Int(next) else { return }
            page = nextPage
        }
    }
}
