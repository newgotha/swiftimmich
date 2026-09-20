import SwiftUI

struct PlacesView: View {
    let service: ImmichService

    @State private var cities: [(city: String, asset: AssetSummary)] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]
    private let contentLeadingPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Places")
                .font(.title2.weight(.bold))
                .padding(.leading, contentLeadingPadding)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(cities, id: \.city) { entry in
                        NavigationLink {
                            CityAssetsView(service: service, city: entry.city)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImageView(
                                    cacheKey: "city-\(entry.city)",
                                    request: service.thumbnailRequest(assetId: entry.asset.id, isImage: entry.asset.isImage)
                                )
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text(entry.city)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading places…")
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if cities.isEmpty {
                    Text("No places found yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .task {
            guard cities.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                cities = try await service.fetchCityHighlights()
            } catch {
                errorMessage = "Couldn't load places: \(error)"
            }
        }
    }
}

private struct CityAssetsView: View {
    let service: ImmichService
    let city: String

    @State private var assets: [AssetSummary] = []
    @State private var errorMessage: String?

    var body: some View {
        FlatAssetGridView(title: city, assets: assets, service: service) { id in
            assets.removeAll { $0.id == id }
        }
        .overlay {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .task {
            guard assets.isEmpty else { return }
            do {
                assets = try await service.fetchAssets(inCity: city)
            } catch {
                errorMessage = "Couldn't load photos for \(city): \(error)"
            }
        }
    }
}
