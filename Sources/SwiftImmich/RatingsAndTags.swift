import ImmichAPI
import SwiftUI

typealias Tag = Components.Schemas.TagResponseDto

@MainActor
extension GridSelection {
    // MARK: - Toast

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Ratings

    /// `nil` clears the rating.
    func setRating(_ assets: [AssetSummary], to rating: Int?) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            if let rating {
                try await service.setRating(assetIds: ids, rating: rating)
                showToast(String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating))
            } else {
                try await service.clearRating(assetIds: ids)
                showToast("Rating cleared")
            }
            NotificationCenter.default.post(name: .assetMetadataChanged, object: ids)
        } catch {
            message = "Couldn't change the rating: \(Self.describeError(error))"
        }
    }

    // MARK: - Locked Folder

    func setLocked(_ assets: [AssetSummary], to locked: Bool) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.setLocked(assetIds: ids, locked: locked)
            if locked {
                // Its thumbnails were cached while it was an ordinary photo; don't leave them behind.
                for id in ids { await ThumbnailLoader.shared.invalidate(assetId: id) }
            }
            deselect(ids)
            NotificationCenter.default.post(name: .assetsRemoved, object: ids)
            showToast(locked ? "Moved to Locked Folder" : "Removed from Locked Folder")
        } catch {
            let hint = locked ? " If you haven't set a PIN yet, open the Locked Folder first." : ""
            message = "Couldn't change the Locked Folder: \(Self.describeError(error))." + hint
        }
    }

    // MARK: - Tags

    func tag(_ assets: [AssetSummary], with tag: Tag) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.tagAssets(ids, with: tag.id)
            showToast("Tagged “\(tag.name)”")
            NotificationCenter.default.post(name: .assetMetadataChanged, object: ids)
        } catch {
            message = "Couldn't add the tag: \(Self.describeError(error))"
        }
    }

    func createTag(named name: String, for assets: [AssetSummary]) async {
        guard let service else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let tag = try await service.createTag(name: trimmed)
            tags.append(tag)
            tags.sort { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            onTagsChanged?()
            if !assets.isEmpty { await self.tag(assets, with: tag) }
        } catch {
            message = "Couldn't create the tag: \(Self.describeError(error))"
        }
    }

    func untag(_ assets: [AssetSummary], from tag: (id: String, name: String), removeFromGrid: Bool = true) async {
        guard let service, !assets.isEmpty else { return }
        let ids = assets.map(\.id)
        do {
            try await service.untagAssets(ids, from: tag.id)
            deselect(ids)
            if removeFromGrid { NotificationCenter.default.post(name: .assetsRemoved, object: ids) }
            NotificationCenter.default.post(name: .assetMetadataChanged, object: ids)
            showToast("Removed from “\(tag.name)”")
        } catch {
            message = "Couldn't remove the tag: \(Self.describeError(error))"
        }
    }

    func delete(_ tag: Tag) async {
        guard let service else { return }
        do {
            try await service.deleteTag(id: tag.id)
            tags.removeAll { $0.id == tag.id }
            onTagsChanged?()
        } catch {
            message = "Couldn't delete the tag: \(Self.describeError(error))"
        }
    }

    static func describeError(_ error: Error) -> String {
        AppLog.error("action failed", error)
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "the server responded \(status)" + (message.map { " — \($0.prefix(200))" } ?? "")
        }
        return error.localizedDescription
    }
}

/// Right-click items for rating and tagging photos.
struct RateAndTagMenu: View {
    let targets: [AssetSummary]
    let filter: TimelineFilter
    @EnvironmentObject private var selection: GridSelection

    var body: some View {
        Menu {
            ForEach(1...5, id: \.self) { stars in
                Button(String(repeating: "★", count: stars)) {
                    Task { await selection.setRating(targets, to: stars) }
                }
            }
            Divider()
            Button("Clear Rating") { Task { await selection.setRating(targets, to: nil) } }
        } label: {
            Label("Rate", systemImage: "star")
        }

        Menu {
            ForEach(selection.tags, id: \.id) { tag in
                Button(tag.value) { Task { await selection.tag(targets, with: tag) } }
            }
            if !selection.tags.isEmpty { Divider() }
            Button("New Tag…") { selection.pendingNewTag = targets }
        } label: {
            Label("Tag", systemImage: "tag")
        }

        if case let .tag(id, name) = filter {
            Button {
                Task { await selection.untag(targets, from: (id: id, name: name)) }
            } label: {
                Label("Remove from “\(name)”", systemImage: "tag.slash")
            }
        }
    }
}

/// Dialogs for tags, plus the brief toast — a modifier of its own because
/// ContentView's body is at the compiler's type-checking limit.
struct TagDialogsAndToast: ViewModifier {
    @ObservedObject var selection: GridSelection
    @State private var newTagName = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: selection.pendingNewTag?.count) { _, _ in
                if selection.pendingNewTag != nil { newTagName = "" }
            }
            .alert("New Tag", isPresented: Binding(
                get: { selection.pendingNewTag != nil },
                set: { if !$0 { selection.pendingNewTag = nil } }
            )) {
                TextField("Tag name", text: $newTagName)
                Button("Create") {
                    let assets = selection.pendingNewTag ?? []
                    selection.pendingNewTag = nil
                    let name = newTagName
                    Task { await selection.createTag(named: name, for: assets) }
                }
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use a slash for nested tags, like Travel/Italy.")
            }
            .confirmationDialog(
                "Delete the tag “\(selection.pendingDeleteTag?.name ?? "")”?",
                isPresented: Binding(
                    get: { selection.pendingDeleteTag != nil },
                    set: { if !$0 { selection.pendingDeleteTag = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Tag", role: .destructive) {
                    guard let tag = selection.pendingDeleteTag else { return }
                    selection.pendingDeleteTag = nil
                    Task { await selection.delete(tag) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the tag from your photos. The photos aren't deleted.")
            }
            .overlay(alignment: .top) {
                if let toast = selection.toast {
                    Text(toast)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.top, 60)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selection.toast)
    }
}

/// The Tags group in the sidebar.
struct TagsSidebarGroup: View {
    @ObservedObject var selection: GridSelection
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(selection.tags, id: \.id) { tag in
                Label(tag.value, systemImage: "tag")
                    .lineLimit(1)
                    .padding(.vertical, 2)
                    .tag(SidebarSelection.tag(id: tag.id, name: tag.value))
                    .contextMenu {
                        Button("Delete Tag…", role: .destructive) { selection.pendingDeleteTag = tag }
                    }
            }
        } label: {
            Label("Tags", systemImage: "tag")
                .padding(.vertical, 4)
        }
    }
}

/// Photos with a given star rating.
struct RatedView: View {
    let service: ImmichService
    @State private var stars = 5
    @State private var assets: [AssetSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        FlatAssetGridView(
            title: "Rated " + String(repeating: "★", count: stars),
            assets: assets,
            service: service,
            subtitle: "Photos you've given exactly \(stars) \(stars == 1 ? "star" : "stars"). Press 1–5 while looking at a photo to rate it.",
            isLoading: isLoading,
            header: AnyView(
                Picker("", selection: $stars) {
                    ForEach((1...5).reversed(), id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            )
        ) { id in
            assets.removeAll { $0.id == id }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).padding() }
        }
        .task(id: stars) {
            assets = []
            isLoading = true
            errorMessage = nil
            do {
                for try await snapshot in service.ratedSnapshots(stars) {
                    if Task.isCancelled { return }
                    assets = snapshot
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errorMessage = "Couldn't load rated photos: \(error)"
            }
            if !Task.isCancelled { isLoading = false }
        }
        // Re-rating something removes (or adds) it here, so re-read.
        .onReceive(NotificationCenter.default.publisher(for: .assetMetadataChanged)) { _ in
            Task {
                var latest: [AssetSummary] = []
                if let snapshots = try? await service.ratedSnapshots(stars).reduce(into: [[AssetSummary]](), { $0.append($1) }), let last = snapshots.last {
                    latest = last
                }
                assets = latest
            }
        }
    }
}
