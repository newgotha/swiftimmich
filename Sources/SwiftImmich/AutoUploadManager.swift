import CryptoKit
import Foundation

/// Watches a local folder and uploads any file that shows up in it after watching
/// began — new photos/videos only, not a one-time backfill of what's already there.
@MainActor
final class AutoUploadManager: ObservableObject {
    @Published private(set) var isWatching = false
    @Published var lastError: String?
    @Published private(set) var uploadedCount = 0
    @Published private(set) var recentLog: [String] = []

    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pollTask: Task<Void, Never>?
    private var folderURL: URL?
    private var service: ImmichService?

    /// Files already accounted for (uploaded, or present before watching started),
    /// keyed by path + modification time so an edited/replaced file re-uploads.
    private var seenKeys: Set<String>
    private let seenKeysDefaultsKey: String

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp",
        "dng", "cr2", "cr3", "nef", "arw", "raf",
        "mp4", "mov", "avi", "mkv", "webm", "3gp",
    ]

    init(persistenceKey: String = "autoUploadSeenKeys") {
        self.seenKeysDefaultsKey = persistenceKey
        let stored = UserDefaults.standard.stringArray(forKey: persistenceKey) ?? []
        self.seenKeys = Set(stored)
    }

    func start(folderPath: String, service: ImmichService) {
        stop()
        guard !folderPath.isEmpty else { return }

        let url = URL(fileURLWithPath: folderPath, isDirectory: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            lastError = "Couldn't open folder for watching: \(url.path)"
            return
        }

        self.folderURL = url
        self.service = service
        self.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { await self?.scanAndUpload() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
        }
        source.resume()
        dispatchSource = source
        isWatching = true
        lastError = nil

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanAndUpload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
        pollTask?.cancel()
        pollTask = nil
        folderURL = nil
        service = nil
        isWatching = false
    }

    private func scanAndUpload() async {
        guard let folderURL, let service else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return }

        for fileURL in entries {
            guard Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  resourceValues.isRegularFile == true,
                  let modifiedAt = resourceValues.contentModificationDate
            else { continue }

            let key = "\(fileURL.path)|\(modifiedAt.timeIntervalSince1970)"
            guard !seenKeys.contains(key) else { continue }

            do {
                try await upload(fileURL: fileURL, modifiedAt: modifiedAt, service: service)
                seenKeys.insert(key)
                persistSeenKeys()
                uploadedCount += 1
                recentLog.insert(fileURL.lastPathComponent, at: 0)
                if recentLog.count > 20 { recentLog.removeLast() }
            } catch {
                lastError = "Failed to upload \(fileURL.lastPathComponent): \(error)"
            }
        }
    }

    /// Marks whatever's currently in the folder as already accounted for, without
    /// uploading it — called once, the first time a folder is chosen, so turning this
    /// on doesn't surprise-upload an entire existing folder.
    func seedExistingContents(ofFolderAt path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for fileURL in entries {
            guard let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            seenKeys.insert("\(fileURL.path)|\(modifiedAt.timeIntervalSince1970)")
        }
        persistSeenKeys()
    }

    private func upload(fileURL: URL, modifiedAt: Date, service: ImmichService) async throws {
        let data = try Data(contentsOf: fileURL)
        let createdAt = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? modifiedAt
        let checksum = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        _ = try await service.uploadAsset(
            data: data,
            filename: fileURL.lastPathComponent,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            checksum: checksum
        )
    }

    private func persistSeenKeys() {
        UserDefaults.standard.set(Array(seenKeys), forKey: seenKeysDefaultsKey)
    }
}
