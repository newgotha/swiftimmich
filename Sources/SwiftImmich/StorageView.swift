import ImmichAPI
import SwiftUI

/// Looks through the library for the biggest photos and videos, so space can be freed.
@MainActor
final class StorageScanModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case videos = "Videos", photos = "Photos", both = "Both"
        var id: String { rawValue }
    }

    @Published private(set) var items: [ImmichService.LargeItem] = []
    @Published private(set) var scanned = 0
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published var errorMessage: String?

    /// Only the biggest are kept, so a huge library can't fill memory.
    private static let keep = 300
    private var task: Task<Void, Never>?

    func start(kind: Kind, service: ImmichService) {
        guard !isScanning else { return }
        items = []
        scanned = 0
        errorMessage = nil
        isScanning = true
        hasScanned = true
        task = Task {
            var base = 0
            do {
                for videos in (kind == .photos ? [false] : kind == .videos ? [true] : [true, false]) {
                    let offset = base
                    base += try await service.scanSizes(videos: videos) { page, count in
                        Task { @MainActor in self.absorb(page, scanned: offset + count) }
                    }
                }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                AppLog.error("storage scan", error)
                errorMessage = "Couldn't finish looking: \(error.localizedDescription)"
            }
            isScanning = false
        }
    }

    func stop() {
        task?.cancel()
    }

    func remove(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
    }

    private func absorb(_ page: [ImmichService.LargeItem], scanned: Int) {
        self.scanned = max(self.scanned, scanned)
        items = Array((items + page).sorted { $0.bytes > $1.bytes }.prefix(Self.keep))
    }
}

struct StorageView: View {
    let service: ImmichService

    @StateObject private var scan = StorageScanModel()
    @State private var storage: ImmichService.StorageInfo?
    @State private var usage: ImmichService.LibraryUsage?
    @State private var kind: StorageScanModel.Kind = .videos
    @State private var selected: Set<String> = []
    @State private var confirmTrash = false
    @State private var message: String?

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    private var selectedBytes: Int64 { scan.items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            CardPage(maxWidth: 720) {
                Text("Storage")
                    .font(.title2.weight(.semibold))
                overview
                finder
                if !scan.items.isEmpty { results }
            }

            if !selected.isEmpty { actionBar }
        }
        .navigationTitle("")
        .task {
            storage = try? await service.fetchStorage()
            usage = try? await service.fetchLibraryUsage()
        }
        .confirmationDialog(
            "Move \(selected.count) \(selected.count == 1 ? "item" : "items") to Recently Deleted?",
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Recently Deleted", role: .destructive) { Task { await trashSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("That frees about \(Self.size(selectedBytes)) once the trash is emptied. Until then they can be restored.")
        }
    }

    // MARK: - Sections

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let storage {
                Text("Server disk").font(.headline)
                ProgressView(value: min(max(storage.fraction, 0), 1))
                Text("\(storage.used) used of \(storage.total) — \(storage.available) free")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let usage {
                Text("\(usage.photos.formatted()) photos using \(Self.size(usage.usagePhotos)) · \(usage.videos.formatted()) videos using \(Self.size(usage.usageVideos))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var finder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find the biggest files").font(.headline)
            Text("Looks through everything on the server and lists the 300 largest, so you can move the ones you don't need to Recently Deleted. Videos take the most space; photos is slower on a big library.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("", selection: $kind) {
                    ForEach(StorageScanModel.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .disabled(scan.isScanning)

                if scan.isScanning {
                    Button("Stop") { scan.stop() }
                    ProgressView().controlSize(.small)
                    Text("Looked at \(scan.scanned.formatted()) items…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(scan.hasScanned ? "Look Again" : "Find Largest Files") {
                        selected = []
                        scan.start(kind: kind, service: service)
                    }
                    .buttonStyle(.borderedProminent)
                    if scan.hasScanned && scan.errorMessage == nil {
                        Text("Looked at \(scan.scanned.formatted()) items.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = scan.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(scan.items) { item in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(item.id) },
                        set: { on in if on { selected.insert(item.id) } else { selected.remove(item.id) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    CoverImageView(
                        cacheKey: item.id,
                        request: service.thumbnailRequest(assetId: item.id, isImage: false)
                    )
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout).lineLimit(1)
                        Text([item.asset.isImage ? "Photo" : "Video", item.asset.date.map { Self.dateFormat.string(from: $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.size(item.bytes)).font(.callout.weight(.semibold)).monospacedDigit()

                    NavigationLink {
                        PhotoViewerView(assets: [item.asset], initialIndex: 0, service: service) { id in
                            scan.remove([id])
                            selected.remove(id)
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open photo")
                    .help("Open")
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Text("\(selected.count) selected · \(Self.size(selectedBytes))")
                .font(.callout)
            Spacer()
            Button("Clear Selection") { selected = [] }
            Button("Move to Recently Deleted…", role: .destructive) { confirmTrash = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func trashSelected() async {
        let ids = selected
        do {
            try await service.trashAssets(Array(ids))
            scan.remove(ids)
            selected = []
            message = "Moved \(ids.count) \(ids.count == 1 ? "item" : "items") to Recently Deleted."
            NotificationCenter.default.post(name: .assetsRemoved, object: Array(ids))
        } catch {
            AppLog.error("storage cleanup", error)
            message = "Couldn't move them: \(error.localizedDescription)"
        }
    }
}
