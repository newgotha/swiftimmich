import AppKit
import Photos
import SwiftUI

/// Compares the Photos library with what's on the Immich server, so anything that never made
/// it across (or was removed from the server) can be found and imported.
///
/// Matching is by original file name and the time the photo was taken — the two things the
/// import preserves — so nothing needs downloading from iCloud to check. A photo edited or
/// renamed on the server can therefore look "missing"; importing it is harmless, since the
/// server recognises a file it already has and skips it.
@MainActor
final class BackupCheckModel: ObservableObject {
    struct LocalItem: Identifiable {
        let id: String        // Photos local identifier
        let name: String
        let date: Date?
        let isVideo: Bool
    }

    enum Phase: Equatable {
        case idle, readingPhotos, readingServer, done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var photosCount = 0
    @Published private(set) var serverCount = 0
    @Published private(set) var missing: [LocalItem] = []
    @Published private(set) var lastChecked: Date?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .readingPhotos || phase == .readingServer }
    var matched: Int { photosCount - missing.count }

    func start(service: ImmichService) {
        guard !isRunning else { return }
        errorMessage = nil
        missing = []
        photosCount = 0
        serverCount = 0
        phase = .readingPhotos
        task = Task {
            do {
                let local = await Task.detached(priority: .userInitiated) { Self.readPhotosLibrary() }.value
                photosCount = local.count
                phase = .readingServer
                let server = try await service.scanServerFiles { count in
                    Task { @MainActor in self.serverCount = count }
                }
                missing = Self.findMissing(local: local, server: server)
                lastChecked = Date()
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch {
                AppLog.error("backup check", error)
                errorMessage = "Couldn't finish the check: \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    func cancel() { task?.cancel() }

    // MARK: - Reading and comparing

    /// Every photo and video in Photos, with the original file name the import would use.
    nonisolated private static func readPhotosLibrary() -> [LocalItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        var items: [LocalItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let types: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
            guard let primary = types.lazy.compactMap({ type in resources.first { $0.type == type } }).first else { return }
            items.append(LocalItem(
                id: asset.localIdentifier, name: primary.originalFilename,
                date: asset.creationDate, isVideo: asset.mediaType == .video
            ))
        }
        return items
    }

    /// Items with no server file of the same name taken within a couple of seconds.
    nonisolated static func findMissing(local: [LocalItem], server: [ImmichService.ServerFile]) -> [LocalItem] {
        var byName: [String: [Date]] = [:]
        for file in server { byName[file.name.lowercased(), default: []].append(file.date) }
        return local.filter { item in
            guard let dates = byName[item.name.lowercased()] else { return true }
            guard let taken = item.date else { return false }   // named match, no date to compare
            return !dates.contains { abs($0.timeIntervalSince(taken)) <= 2 }
        }
    }
}

struct BackupCheckView: View {
    let service: ImmichService
    @ObservedObject var importer: PhotosImporter
    @StateObject private var model = BackupCheckModel()

    private static let shown = 60

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    var body: some View {
        CardPage(maxWidth: 680) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backup Check").font(.title2.weight(.semibold))
                Text("Compares your Photos library with your Immich server and lists anything that isn't there yet.")
                    .foregroundStyle(.secondary)
            }

            if !importer.isAuthorized {
                Label("Allow access to Photos on the Import from Photos page first.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else {
                controls
                if model.phase == .done { results }
            }
        }
        .task {
            importer.configure(serverIdentity: service.apiURL.absoluteString)
            importer.refreshAuthorization()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                Button("Stop") { model.cancel() }
                ProgressView().controlSize(.small)
                Text(model.phase == .readingPhotos
                     ? "Reading your Photos library…"
                     : "Reading your server… \(model.serverCount.formatted()) files")
                    .foregroundStyle(.secondary)
            } else {
                Button(model.lastChecked == nil ? "Check Now" : "Check Again") { model.start(service: service) }
                    .buttonStyle(.borderedProminent)
                    .disabled(importer.isRunning)
                if let last = model.lastChecked {
                    Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var results: some View {
        HStack(spacing: 28) {
            stat("In Photos", model.photosCount)
            stat("On your server", model.matched)
            stat("Missing", model.missing.count, warning: !model.missing.isEmpty)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        if model.missing.isEmpty {
            Label("Everything in Photos is on your server.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.missing.count == 1 ? "1 item isn't on your server" : "\(model.missing.count.formatted()) items aren't on your server")
                        .font(.headline)
                    Spacer()
                    Button("Import \(model.missing.count.formatted()) Missing") {
                        importer.startImport(identifiers: model.missing.map(\.id), service: service)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importer.isRunning)
                }
                if importer.isRunning {
                    Label("Importing… \(importer.processed) of \(importer.totalToProcess). Check again when it finishes.", systemImage: "arrow.up.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.missing.prefix(Self.shown)) { item in
                    HStack(spacing: 10) {
                        LocalThumbnail(identifier: item.id)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Text([item.isVideo ? "Video" : "Photo", item.date.map { Self.dateFormat.string(from: $0) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.missing.count > Self.shown {
                    Text("…and \((model.missing.count - Self.shown).formatted()) more")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Matching is by file name and the time taken, so a photo you renamed or edited on the server can appear here. Importing it is harmless — the server skips anything it already has.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ title: String, _ value: Int, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(warning ? Color.orange : Color.primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A small thumbnail of an item in the Photos library.
struct LocalThumbnail: View {
    let identifier: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.15))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .task(id: identifier) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
            image = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = false
                var resumed = false
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 96, height: 96), contentMode: .aspectFill, options: options
                ) { result, info in
                    // Opportunistic delivery may call back twice; finish on the first usable image.
                    guard !resumed else { return }
                    if let result { resumed = true; continuation.resume(returning: result) }
                    else if (info?[PHImageResultIsDegradedKey] as? Bool) != true { resumed = true; continuation.resume(returning: nil) }
                }
            }
        }
    }
}
