import AppKit
import CryptoKit
import ImmichAPI
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by File > Upload Files… so the window that owns the upload machinery can
    /// open its file picker.
    static let requestUploadPanel = Notification.Name("dev.local.swiftimmich.requestUploadPanel")
}

/// Runs one upload or download batch at a time and reports its progress for the banner
/// at the bottom of the window: files dropped on the window (or picked with File >
/// Upload Files…) go up to Immich, and "Download Original…" saves photos to disk.
@MainActor
final class TransferCenter: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var currentName = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var isRunning = false
    @Published private(set) var summary: String?
    @Published private(set) var failures: [String] = []

    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    var isVisible: Bool { isRunning || summary != nil }

    func cancel() { task?.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        summary = nil
        failures = []
    }

    // MARK: - Uploading

    /// Uploads files and folders (searched recursively) of photos and videos.
    func upload(_ urls: [URL], service: ImmichService) {
        guard !isRunning else { return }
        begin(title: "Uploading")
        task = Task {
            let files = await Task.detached(priority: .userInitiated) { Self.mediaFiles(in: urls) }.value
            guard !files.isEmpty else {
                finish("No photos or videos found to upload.")
                return
            }
            total = files.count
            var created = 0, duplicates = 0
            for file in files {
                if Task.isCancelled { break }
                currentName = file.lastPathComponent
                do {
                    switch try await Self.uploadOne(file, service: service) {
                    case .created: created += 1
                    case .duplicate: duplicates += 1
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(file.lastPathComponent): \(Self.describe(error))")
                }
                completed += 1
            }
            if created > 0 { NotificationCenter.default.post(name: .gridNeedsReload, object: nil) }

            var parts: [String] = []
            if created > 0 { parts.append("Uploaded \(created) \(created == 1 ? "item" : "items")") }
            if duplicates > 0 { parts.append("\(duplicates) already in your library") }
            if !failures.isEmpty { parts.append("\(failures.count) failed") }
            if Task.isCancelled { parts.append("stopped early") }
            finish(parts.isEmpty ? "Nothing uploaded." : parts.joined(separator: " · ") + ".")
        }
    }

    /// Asks for files or folders, then uploads them.
    func chooseAndUpload(service: ImmichService) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.message = "Choose photos, videos or folders to upload to Immich."
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, service: service)
    }

    private static func uploadOne(_ file: URL, service: ImmichService) async throws -> ImmichService.UploadResult {
        let values = try file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let modified = values.contentModificationDate ?? Date()
        let created = values.creationDate ?? modified
        let checksum = try await Task.detached(priority: .utility) { try sha1(of: file) }.value
        return try await service.uploadAsset(
            fileURL: file, filename: file.lastPathComponent,
            createdAt: created, modifiedAt: modified, checksum: checksum
        )
    }

    private nonisolated static func sha1(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every photo/video among the given files, plus everything inside the given folders.
    private nonisolated static func mediaFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        func consider(_ url: URL) {
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
                  type.conforms(to: .image) || type.conforms(to: .movie)
            else { return }
            result.append(url)
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                guard let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let child as URL in walker {
                    if (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { consider(child) }
                }
            } else {
                consider(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    // MARK: - Downloading

    /// Saves the photos/videos to disk: one asks where and under what name, several ask
    /// for a folder. Photos are saved as they appear in Immich (edits included).
    func download(_ assets: [AssetSummary], service: ImmichService) {
        guard !isRunning, !assets.isEmpty else { return }

        if assets.count == 1, let asset = assets.first {
            begin(title: "Downloading")
            total = 1
            task = Task {
                do {
                    let file = try await service.downloadForSharing(assetId: asset.id, isImage: asset.isImage)
                    completed = 1
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = file.lastPathComponent
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let destination = panel.url {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.copyItem(at: file, to: destination)
                        finish("Saved “\(destination.lastPathComponent)”.")
                    } else {
                        finish(nil)
                    }
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                } catch {
                    failures.append(Self.describe(error))
                    finish("Couldn't download.")
                }
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for \(assets.count) items."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        begin(title: "Downloading")
        total = assets.count
        task = Task {
            var saved = 0
            for asset in assets {
                if Task.isCancelled { break }
                currentName = ""
                do {
                    let file = try await service.downloadForSharing(assetId: asset.id, isImage: asset.isImage)
                    currentName = file.lastPathComponent
                    try Self.move(file, into: folder)
                    saved += 1
                } catch is CancellationError {
                    break
                } catch {
                    failures.append(Self.describe(error))
                }
                completed += 1
            }
            var text = "Saved \(saved) \(saved == 1 ? "item" : "items") to “\(folder.lastPathComponent)”"
            if !failures.isEmpty { text += " · \(failures.count) failed" }
            finish(text + ".")
        }
    }

    /// Moves a downloaded file into the folder, adding " 2", " 3"… rather than overwriting.
    private static func move(_ file: URL, into folder: URL) throws {
        let fm = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        var destination = folder.appendingPathComponent(file.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        try fm.moveItem(at: file, to: destination)
        try? fm.removeItem(at: file.deletingLastPathComponent())
    }

    // MARK: - Bookkeeping

    private func begin(title: String) {
        dismissTask?.cancel()
        self.title = title
        currentName = ""
        completed = 0
        total = 0
        summary = nil
        failures = []
        isRunning = true
    }

    private func finish(_ text: String?) {
        isRunning = false
        summary = text
        task = nil
        // A clean result clears itself; anything that failed stays until dismissed.
        if failures.isEmpty {
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { dismiss() }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        AppLog.error("transfer failed", error)
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            return "the server said \(status)" + (message.map { " — \($0.prefix(120))" } ?? "")
        }
        return error.localizedDescription
    }
}

/// The progress / result strip at the bottom of the window.
struct TransferBanner: View {
    @ObservedObject var center: TransferCenter

    var body: some View {
        if center.isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if center.isRunning {
                        ProgressView(value: Double(center.completed), total: Double(max(center.total, 1)))
                            .frame(width: 120)
                        Text(runningText)
                            .font(.callout)
                            .lineLimit(1)
                        Button("Stop") { center.cancel() }
                    } else if let summary = center.summary {
                        Image(systemName: center.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(center.failures.isEmpty ? Color.green : Color.orange)
                        Text(summary)
                            .font(.callout)
                        Button { center.dismiss() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                }
                if !center.isRunning, let first = center.failures.first {
                    Text(first)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var runningText: String {
        let position = center.total > 0 ? " \(min(center.completed + 1, center.total)) of \(center.total)" : ""
        let name = center.currentName.isEmpty ? "" : " — \(center.currentName)"
        return "\(center.title)\(position)\(name)"
    }
}

/// Lets files be dropped anywhere on the window to upload them, shows the transfer
/// banner, and answers File > Upload Files…. A modifier of its own because ContentView's
/// body is at the compiler's type-checking limit.
struct FileDropUpload: ViewModifier {
    let service: ImmichService?
    @ObservedObject var center: TransferCenter
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let service else { return false }
                Task { await handle(providers, service: service) }
                return true
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                        .background(Color.accentColor.opacity(0.08))
                        .overlay {
                            Label("Drop to upload to Immich", systemImage: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .padding(16)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) { TransferBanner(center: center) }
            .animation(Motion.animation(.easeInOut(duration: 0.2)), value: center.isVisible)
            .onReceive(NotificationCenter.default.publisher(for: .requestUploadPanel)) { _ in
                if let service { center.chooseAndUpload(service: service) }
            }
    }

    private func handle(_ providers: [NSItemProvider], service: ImmichService) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await Self.fileURL(from: provider) { urls.append(url) }
        }
        if !urls.isEmpty { center.upload(urls, service: service) }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
