import SwiftUI

/// One "Media Types" sidebar filter's results, filling in as pages arrive.
struct MediaTypeView: View {
    let service: ImmichService
    let type: MediaType

    @State private var assets: [AssetSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        FlatAssetGridView(
            title: type.title,
            assets: assets,
            service: service,
            subtitle: type.explanation,
            isLoading: isLoading
        ) { id in
            assets.removeAll { $0.id == id }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        // Re-runs (cancelling the previous load) when the user picks a different type.
        .task(id: type) {
            assets = []
            isLoading = true
            errorMessage = nil
            do {
                for try await snapshot in service.mediaTypeSnapshots(type) {
                    if Task.isCancelled { return }
                    assets = snapshot
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = "Couldn't load \(type.title): \(error)"
            }
            // Only the still-current load may clear this: a cancelled one finishing
            // late would otherwise hide the spinner of the load that replaced it.
            if !Task.isCancelled { isLoading = false }
        }
    }
}
