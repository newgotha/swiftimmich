import Foundation
import ImmichAPI

/// A single asset, unpacked from Immich's column-oriented `TimeBucketAssetResponseDto`
/// (the API returns one array per field, parallel-indexed, rather than an array of objects).
struct AssetSummary: Identifiable, Hashable, Codable {
    let id: String
    var isFavorite: Bool
    let isImage: Bool
    let ratio: Double
    /// When it was taken/created — lets results from several separate queries be
    /// merged back into one newest-first list.
    var date: Date? = nil
    /// Set on the cover photo of a stack (a group of related photos shown as one).
    var stackId: String? = nil
    var stackCount = 0
    /// Who owns it; nil when unknown (treated as yours). Differs for a partner's photos.
    var ownerId: String? = nil
    /// The motion clip of a Live Photo.
    var livePhotoVideoId: String? = nil

    private static let fractionalDateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDateParser = ISO8601DateFormatter()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractionalDateParser.date(from: string) ?? plainDateParser.date(from: string)
    }

    static func makeSummaries(from dto: Components.Schemas.TimeBucketAssetResponseDto) -> [AssetSummary] {
        let ids = dto.id
        return ids.indices.map { index in
            let stack = dto.stack?[safe: index] ?? nil
            let stackCount = stack.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? 0
            return AssetSummary(
                id: ids[index],
                isFavorite: dto.isFavorite[safe: index] ?? false,
                isImage: dto.isImage[safe: index] ?? true,
                ratio: dto.ratio[safe: index] ?? 1.0,
                date: parseDate(dto.fileCreatedAt[safe: index] ?? nil),
                stackId: stackCount > 1 ? stack?.first : nil,
                stackCount: stackCount,
                ownerId: dto.ownerId[safe: index],
                livePhotoVideoId: dto.livePhotoVideoId[safe: index] ?? nil
            )
        }
    }

    /// Builds summaries from a flat list of full asset objects, as returned by
    /// memories, city browsing, and search — as opposed to the columnar timeline format.
    static func makeSummaries(from assets: [Components.Schemas.AssetResponseDto]) -> [AssetSummary] {
        assets.map { asset in
            let width = asset.width.map(Double.init) ?? 1
            let height = asset.height.map(Double.init) ?? 1
            return AssetSummary(
                id: asset.id,
                isFavorite: asset.isFavorite,
                isImage: asset._type == .IMAGE,
                ratio: height > 0 ? width / height : 1.0,
                date: asset.fileCreatedAt,
                ownerId: asset.ownerId,
                livePhotoVideoId: asset.livePhotoVideoId
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
