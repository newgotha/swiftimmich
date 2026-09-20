import SwiftUI

/// A single ungrouped grid of assets, for collections that come back as one flat
/// list already (a memory's assets, a city's assets) rather than as time buckets.
struct FlatAssetGridView: View {
    let title: String
    let assets: [AssetSummary]
    let service: ImmichService
    /// Explains how the list was chosen, for filters that are inferred rather than exact.
    var subtitle: String? = nil
    /// True while more results may still be arriving.
    var isLoading = false
    /// Extra controls shown between the title and the photos (e.g. search filters).
    var header: AnyView? = nil
    var onDelete: ((String) -> Void)? = nil

    /// Matches PhotoGridView's contentLeadingPadding, for the same reason: the title
    /// is rendered as content (not the system toolbar title) so it can share an exact
    /// left edge with the grid below it.
    private let contentLeadingPadding: CGFloat = 20

    /// Flat lists start as one run (search results are ordered by how well they match, which
    /// grouping by date would scramble), but can be grouped by month or year.
    @State private var grouping: TimelineGrouping = .all

    private struct DateGroup {
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

    /// The photos newest first, split by month or year.
    private var groups: [DateGroup] {
        let formatter = grouping == .years ? Self.yearFormat : Self.monthFormat
        var order: [String] = []
        var buckets: [String: [AssetSummary]] = [:]
        for asset in assets.sorted(by: { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) {
            let key = asset.date.map { formatter.string(from: $0) } ?? "Unknown Date"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(asset)
        }
        return order.map { DateGroup(title: $0, assets: buckets[$0] ?? []) }
    }

    private func groupHeader(_ title: String) -> some View {
        SectionHeader(title: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                if isLoading && !assets.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.top, 12)
            .padding(.bottom, subtitle == nil ? 4 : 0)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, contentLeadingPadding)
                    .padding(.bottom, 6)
            }

            if let header {
                header
                    .padding(.leading, contentLeadingPadding)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }

            ScrollView {
                if grouping == .all {
                    JustifiedAssetGridView(assets: assets, service: service, onDelete: onDelete)
                        .padding(.leading, contentLeadingPadding)
                        .padding(.trailing, 16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.title) { group in
                            Section {
                                JustifiedAssetGridView(assets: group.assets, service: service, onDelete: onDelete)
                            } header: {
                                groupHeader(group.title)
                            }
                        }
                    }
                    .padding(.leading, contentLeadingPadding)
                    .padding(.trailing, 16)
                }
            }
            .overlay {
                if assets.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("No photos found.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                GroupingControl(selection: $grouping)
            }
            SelectToolbarContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetsRemoved)) { note in
            let shown = Set(assets.map(\.id))
            for id in note.object as? [String] ?? [] where shown.contains(id) { onDelete?(id) }
        }
    }
}
