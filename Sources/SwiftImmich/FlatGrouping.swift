import Foundation

/// Splits a flat list of photos (search results, a memory, a place) into months or years,
/// newest first.
enum FlatGrouping {
    struct Group {
        let title: String
        let assets: [AssetSummary]
    }

    private static let monthFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let yearFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    /// Sorting a big list on every redraw is wasteful, and most lists arrive newest first already.
    private static func newestFirst(_ assets: [AssetSummary]) -> [AssetSummary] {
        let alreadyOrdered = zip(assets, assets.dropFirst()).allSatisfy { ($0.date ?? .distantPast) >= ($1.date ?? .distantPast) }
        return alreadyOrdered ? assets : assets.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func groups(for assets: [AssetSummary], by grouping: TimelineGrouping) -> [Group] {
        let formatter = grouping == .years ? yearFormat : monthFormat
        var order: [String] = []
        var buckets: [String: [AssetSummary]] = [:]
        for asset in newestFirst(assets) {
            let key = asset.date.map { formatter.string(from: $0) } ?? "Unknown Date"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(asset)
        }
        return order.map { Group(title: $0, assets: buckets[$0] ?? []) }
    }
}
