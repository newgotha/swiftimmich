import SwiftUI

struct SearchResultsView: View {
    let service: ImmichService
    let query: String

    @EnvironmentObject private var model: SearchModel

    @State private var assets: [AssetSummary] = []
    @State private var nextPage: Int?
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var isLoadingMore = false

    private struct Key: Equatable {
        let query: String
        let filters: SearchFilters
    }

    private var nothingToSearch: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && !model.filters.isActive }

    var body: some View {
        FlatAssetGridView(
            title: "Search",
            assets: assets,
            service: service,
            subtitle: subtitle,
            header: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    SearchFilterBar(service: service, query: query)
                    if nextPage != nil {
                        Button(isLoadingMore ? "Loading…" : "Show More Results") { Task { await loadMore() } }
                            .disabled(isLoadingMore)
                    }
                }
            )
        ) { id in
            assets.removeAll { $0.id == id }
        }
        .overlay {
            if nothingToSearch {
                Text("Type in the search box, or choose filters above.")
                    .foregroundStyle(.secondary)
            } else if isSearching {
                ProgressView("Searching…")
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if assets.isEmpty {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        // .task(id:) auto-cancels the previous search when the words or filters change,
        // which gives us debouncing without any manual Task bookkeeping.
        .task(id: Key(query: query, filters: model.filters)) {
            assets = []
            nextPage = nil
            errorMessage = nil
            guard !nothingToSearch else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let page = try await service.search(query: query, filters: model.filters, page: 1)
                assets = page.assets
                nextPage = page.nextPage
            } catch {
                if !Task.isCancelled { errorMessage = "Search failed: \(error)" }
            }
        }
    }

    private var subtitle: String? {
        guard !assets.isEmpty else { return nil }
        return "\(assets.count) \(assets.count == 1 ? "result" : "results")" + (nextPage != nil ? " so far" : "")
    }

    private func loadMore() async {
        guard let page = nextPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if let more = try? await service.search(query: query, filters: model.filters, page: page) {
            let known = Set(assets.map(\.id))
            assets += more.assets.filter { !known.contains($0.id) }
            nextPage = more.nextPage
        }
    }
}
