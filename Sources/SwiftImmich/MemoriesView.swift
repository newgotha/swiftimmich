import ImmichAPI
import SwiftUI

struct MemoriesView: View {
    let service: ImmichService

    @State private var memories: [Components.Schemas.MemoryResponseDto] = []
    @State private var onThisDay: [(year: Int, assets: [AssetSummary])] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isLoadingToday = false

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]
    private let contentLeadingPadding: CGFloat = 20

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The server's own "on this day" memories for years the timeline lookup didn't already cover.
    private var otherMemories: [Components.Schemas.MemoryResponseDto] {
        let covered = Set(onThisDay.map(\.year))
        return memories.filter { !covered.contains($0.data.year) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Memories")
                .font(.title2.weight(.bold))
                .padding(.leading, contentLeadingPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    todaySection
                    if !otherMemories.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("More memories").font(.headline)
                            LazyVGrid(columns: columns, spacing: 24) {
                                ForEach(otherMemories, id: \.id) { memory in
                                    let assets = AssetSummary.makeSummaries(from: memory.assets)
                                    card(title: "On this day, \(memory.data.year)", assets: assets, key: "memory-\(memory.id)") { id in
                                        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                                            memories[index].assets.removeAll { $0.id == id }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if isLoading && isLoadingToday {
                    ProgressView("Looking for memories…")
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if !isLoading && !isLoadingToday && memories.isEmpty && onThisDay.isEmpty {
                    Text("No memories for today yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .task {
            guard memories.isEmpty, onThisDay.isEmpty else { return }
            isLoading = true
            isLoadingToday = true
            async let today: Void = loadToday()
            do {
                memories = try await service.fetchMemories()
            } catch {
                errorMessage = "Couldn't load memories: \(error)"
            }
            isLoading = false
            await today
        }
    }

    /// Photos taken on today's date in past years, from the timeline itself.
    @ViewBuilder
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("On This Day").font(.headline)
                Text(Self.dayFormat.string(from: Date())).font(.subheadline).foregroundStyle(.secondary)
                if isLoadingToday { ProgressView().controlSize(.small) }
            }
            if onThisDay.isEmpty {
                Text(isLoadingToday ? "Looking through past years…" : "Nothing was photographed on this date in earlier years.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(onThisDay, id: \.year) { entry in
                        let ago = Calendar.current.component(.year, from: Date()) - entry.year
                        card(
                            title: ago == 1 ? "1 year ago" : "\(ago) years ago",
                            subtitle: String(entry.year),
                            assets: entry.assets,
                            key: "onthisday-\(entry.year)-\(entry.assets.first?.id ?? "")"
                        ) { id in
                            if let index = onThisDay.firstIndex(where: { $0.year == entry.year }) {
                                onThisDay[index].assets.removeAll { $0.id == id }
                            }
                        }
                    }
                }
            }
        }
    }

    private func card(
        title: String,
        subtitle: String? = nil,
        assets: [AssetSummary],
        key: String,
        onDelete: @escaping (String) -> Void
    ) -> some View {
        NavigationLink {
            FlatAssetGridView(title: "\(title)\(subtitle.map { " · \($0)" } ?? "")", assets: assets, service: service, onDelete: onDelete)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImageView(
                    cacheKey: key,
                    request: assets.first.map { service.thumbnailRequest(assetId: $0.id, isImage: $0.isImage) }
                )
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(subtitle.map { "\($0) · " } ?? "")\(assets.count) \(assets.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadToday() async {
        defer { isLoadingToday = false }
        do {
            onThisDay = try await service.photosOnThisDay()
        } catch {
            AppLog.error("on this day", error)
        }
    }
}
