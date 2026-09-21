import ImmichAPI
import SwiftUI

typealias DuplicateAsset = Components.Schemas.AssetResponseDto

/// Photos Immich thinks are the same picture, grouped so each group can be reviewed.
/// In each group you choose which photos to keep; the rest go to the trash (still
/// recoverable from Recently Deleted).
@MainActor
final class DuplicatesModel: ObservableObject {
    struct Group: Identifiable {
        let id: String
        var assets: [DuplicateAsset]
        /// The photos that will be kept; everything else in the group gets trashed.
        var keep: Set<String>

        var trash: [String] { assets.map(\.id).filter { !keep.contains($0) } }
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    let service: ImmichService

    init(service: ImmichService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await service.fetchDuplicates().map { dto in
                let ids = Set(dto.assets.map(\.id))
                // Immich suggests which to keep (largest / best metadata); if it doesn't,
                // default to keeping everything so nothing is trashed by accident.
                var keep = Set(dto.suggestedKeepAssetIds).intersection(ids)
                if keep.isEmpty { keep = ids }
                return Group(id: dto.duplicateId, assets: dto.assets, keep: keep)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load duplicates: \(error.localizedDescription)"
        }
    }

    func toggleKeep(groupId: String, assetId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if groups[index].keep.contains(assetId) {
            // Always keep at least one photo.
            guard groups[index].keep.count > 1 else { return }
            groups[index].keep.remove(assetId)
        } else {
            groups[index].keep.insert(assetId)
        }
    }

    /// Applies the current choices: trashes what isn't kept. A group where everything is
    /// kept is just dismissed.
    func resolve(_ groupIds: [String]) async {
        let chosen = groups.filter { groupIds.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let toResolve = chosen.filter { !$0.trash.isEmpty }
            let toDismiss = chosen.filter { $0.trash.isEmpty }
            if !toResolve.isEmpty {
                try await service.resolveDuplicates(toResolve.map { (id: $0.id, keep: Array($0.keep), trash: $0.trash) })
            }
            if !toDismiss.isEmpty {
                try await service.dismissDuplicates(ids: toDismiss.map(\.id))
            }
            let done = Set(chosen.map(\.id))
            groups.removeAll { done.contains($0.id) }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't resolve: \(Self.describe(error))"
        }
    }

    /// "These aren't duplicates": keeps everything and stops flagging the group.
    func keepAll(_ groupId: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.dismissDuplicates(ids: [groupId])
            groups.removeAll { $0.id == groupId }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't dismiss: \(Self.describe(error))"
        }
    }

    /// Called when a photo is deleted from the viewer opened on a group.
    func removeAsset(id: String) {
        for index in groups.indices { groups[index].assets.removeAll { $0.id == id }; groups[index].keep.remove(id) }
        groups.removeAll { $0.assets.count < 2 }
    }

    private static func describe(_ error: Error) -> String {
        AppLog.error("duplicates action failed", error)
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "the server responded \(status)" + (message.map { " — \($0.prefix(200))" } ?? "")
        }
        return error.localizedDescription
    }
}

struct DuplicatesView: View {
    let service: ImmichService
    @StateObject private var model: DuplicatesModel
    @State private var confirmResolveAll = false

    private let contentLeadingPadding: CGFloat = 20

    init(service: ImmichService) {
        self.service = service
        _model = StateObject(wrappedValue: DuplicatesModel(service: service))
    }

    private var trashCountForAll: Int { model.groups.reduce(0) { $0 + $1.trash.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Duplicates")
                        .font(.title2.weight(.bold))
                    if !model.groups.isEmpty {
                        Button("Resolve All…") { confirmResolveAll = true }
                            .buttonStyle(ToolbarPillStyle())
                            .font(.callout)
                            .disabled(model.isWorking)
                        if model.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                Text("Tap a photo to choose whether to keep it. Photos you don't keep are moved to Recently Deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, contentLeadingPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, contentLeadingPadding)
                    .padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.leading, contentLeadingPadding)
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .overlay {
                if model.isLoading && model.groups.isEmpty {
                    ProgressView("Looking for duplicates…")
                } else if model.groups.isEmpty && model.errorMessage == nil {
                    Text("No duplicates found.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .task { await model.load() }
        .confirmationDialog(
            "Resolve \(model.groups.count) groups?",
            isPresented: $confirmResolveAll,
            titleVisibility: .visible
        ) {
            Button("Move \(trashCountForAll) to Recently Deleted", role: .destructive) {
                Task { await model.resolve(model.groups.map(\.id)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each group keeps the photos currently marked Keep. Trashed photos can be restored from Recently Deleted.")
        }
    }

    private func groupCard(_ group: DuplicatesModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.assets, id: \.id) { asset in
                        DuplicateCard(
                            asset: asset,
                            service: service,
                            isKept: group.keep.contains(asset.id),
                            group: group,
                            onOpenDelete: { model.removeAsset(id: $0) }
                        ) {
                            model.toggleKeep(groupId: group.id, assetId: asset.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button("These Aren't Duplicates") {
                    Task { await model.keepAll(group.id) }
                }
                Spacer()
                let trashCount = group.trash.count
                Button {
                    Task { await model.resolve([group.id]) }
                } label: {
                    Text(trashCount == 0 ? "Keep All" : "Keep \(group.keep.count), Trash \(trashCount)")
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(model.isWorking)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DuplicateCard: View {
    let asset: DuplicateAsset
    let service: ImmichService
    let isKept: Bool
    let group: DuplicatesModel.Group
    let onOpenDelete: (String) -> Void
    let toggle: () -> Void

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var details: String {
        var parts: [String] = []
        if let width = asset.exifInfo?.exifImageWidth ?? asset.width, let height = asset.exifInfo?.exifImageHeight ?? asset.height {
            parts.append("\(Int(width)) × \(Int(height))")
        }
        if let size = asset.exifInfo?.fileSizeInByte {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImageView(
                cacheKey: asset.id,
                request: service.thumbnailRequest(assetId: asset.id, isImage: asset._type == .IMAGE)
            )
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                Label(isKept ? "Keep" : "Trash", systemImage: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isKept ? Color.green : Color.red, in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                NavigationLink {
                    PhotoViewerView(
                        assets: AssetSummary.makeSummaries(from: group.assets),
                        initialIndex: group.assets.firstIndex(where: { $0.id == asset.id }) ?? 0,
                        service: service,
                        onDelete: onOpenDelete
                    )
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .accessibilityLabel("Open photo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Open")
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isKept ? Color.green : Color.red.opacity(0.7), lineWidth: 2)
            }

            Text(asset.originalFileName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)
            Text(details)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.dateFormat.string(from: asset.fileCreatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
