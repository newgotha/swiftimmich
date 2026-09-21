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
    @EnvironmentObject private var selection: GridSelection

    private var groups: [FlatGrouping.Group] { FlatGrouping.groups(for: assets, by: grouping) }

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

            ScrollViewReader { proxy in
            ScrollView {
                if grouping == .all {
                    JustifiedAssetGridView(assets: assets, service: service, onDelete: onDelete)
                        .padding(.leading, contentLeadingPadding)
                        .padding(.trailing, 16)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                        let sections = groups
                        ForEach(Array(sections.enumerated()), id: \.element.title) { index, group in
                            Section {
                                JustifiedAssetGridView(assets: group.assets, service: service, order: index, onDelete: onDelete)
                            } header: {
                                groupHeader(group.title)
                            }
                        }
                    }
                    .padding(.leading, contentLeadingPadding)
                    .padding(.trailing, 16)
                }
            }
            .onChange(of: selection.focusedId) { _, id in
                if let id { proxy.scrollTo(id) }
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
