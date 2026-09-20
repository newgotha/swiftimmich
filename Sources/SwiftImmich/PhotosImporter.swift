import CryptoKit
import Foundation
import Photos

/// Copies the user's Photos library — including originals that only live in iCloud —
/// to their Immich server.
///
/// There is no "iCloud API" to talk to; iCloud Photos syncs into the local Photos
/// library, and PhotoKit is the supported way to read that library. For items that
/// aren't stored locally (Optimize Mac Storage), PhotoKit downloads the original
/// from iCloud on demand when network access is allowed, which is what makes this
/// work for a library that isn't fully on disk.
///
/// Each item is exported to a temporary file (streamed, never held in memory),
/// hashed, uploaded with that SHA-1 so the server can recognise something it
/// already has, then the temporary file is deleted.
@MainActor
final class PhotosImporter: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, importing, finished, stopped
    }

    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    private enum Outcome {
        case uploaded
        case alreadyOnServer
        case skipped
    }

    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var librarySize = 0
    @Published private(set) var alreadyImported = 0
    @Published private(set) var processed = 0
    @Published private(set) var totalToProcess = 0
    @Published private(set) var uploaded = 0
    @Published private(set) var alreadyOnServer = 0
    @Published private(set) var skipped = 0
    @Published private(set) var failures: [Failure] = []
    @Published private(set) var currentName: String?
    @Published private(set) var currentDetail: String?
    @Published private(set) var stopReason: String?
    /// Items that failed on an earlier run. They're tried last, so a handful of stubborn
    /// ones can't hold up everything behind them.
    @Published private(set) var previouslyFailedCount = 0

    var pendingCount: Int { pendingIdentifiers.count }
    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }
    var isRunning: Bool { phase == .scanning || phase == .importing }

    private var pendingIdentifiers: [String] = []
    private var ledger = ImportLedger()
    private var runTask: Task<Void, Never>?
    private var isPreparingAutomatic = false

    // MARK: - Authorization and counts

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refreshCounts()
    }

    /// Ties the "already imported" ledger to a specific server, so pointing the app at
    /// a different Immich server doesn't wrongly skip everything as already done.
    func configure(serverIdentity: String) {
        // Re-pointing the ledger mid-run would drop the run's unsaved progress.
        guard !isRunning else { return }
        ledger = ImportLedger(serverIdentity: serverIdentity)
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func refreshCounts() async {
        refreshAuthorization()
        guard isAuthorized, !isRunning else { return }
        let known = ledger.identifiers
        let (total, pending) = await Task.detached(priority: .utility) { Self.scanLibrary(excluding: known) }.value
        librarySize = total
        pendingIdentifiers = pending
        alreadyImported = total - pending.count
        previouslyFailedCount = pending.filter { ledger.failed[$0] != nil }.count
        objectWillChange.send()
    }

    // MARK: - Running an import

    /// `limit` caps how many of the newest not-yet-imported items to process, so a
    /// first run can be a small, easily-checked test.
    func start(service: ImmichService, limit: Int?) {
        guard !isRunning, !isPreparingAutomatic, isAuthorized else { return }
        runTask = Task { await run(service: service, limit: limit) }
    }

    /// Imports exactly these Photos items (used by the backup check to fill in what's missing).
    func startImport(identifiers: [String], service: ImmichService) {
        guard !isRunning, !isPreparingAutomatic, isAuthorized, !identifiers.isEmpty else { return }
        runTask = Task { await run(service: service, limit: nil, only: identifiers) }
    }

    /// Quietly imports what's new in Photos since `since` (photos taken from then on),
    /// skipping anything that already failed once so a stubborn item can't be retried
    /// on every library change. Does nothing — and shows nothing — when there's nothing new.
    func startAutomatic(service: ImmichService, since: Date) {
        guard !isRunning, !isPreparingAutomatic, isAuthorized else { return }
        isPreparingAutomatic = true
        runTask = Task {
            let known = ledger.identifiers
            let failed = ledger.failed
            let (_, pending) = await Task.detached(priority: .utility) {
                Self.scanLibrary(excluding: known, since: since)
            }.value
            let queue = pending.filter { failed[$0] == nil }
            isPreparingAutomatic = false
            guard !queue.isEmpty, !Task.isCancelled else { return }
            Diagnostics.log("automatic import: \(queue.count) new item(s)", to: Self.logFile)
            await run(service: service, limit: nil, only: queue)
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func run(service: ImmichService, limit: Int?, only: [String]? = nil) async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Importing photos to Immich"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        phase = .scanning
        currentName = nil
        currentDetail = "Reading your Photos library…"
        stopReason = nil
        failures = []
        processed = 0
        uploaded = 0
        alreadyOnServer = 0
        skipped = 0

        let failedBefore = ledger.failed
        let queue: [String]
        if let only {
            queue = only
        } else {
            let known = ledger.identifiers
            let (total, pending) = await Task.detached(priority: .utility) { Self.scanLibrary(excluding: known) }.value
            librarySize = total
            // Anything that failed before goes to the back: previously the same few
            // failing items sat at the front every run, so five of them in a row halted the
            // import before it could reach a single new photo.
            let ordered = pending.filter { failedBefore[$0] == nil } + pending.filter { failedBefore[$0] != nil }
            queue = limit.map { Array(ordered.prefix($0)) } ?? ordered
        }
        totalToProcess = queue.count
        phase = .importing
        Diagnostics.log("run started: \(queue.count) to import (\(failedBefore.count) retrying earlier failures last)", to: Self.logFile)

        var consecutiveFailures = 0
        for identifier in queue {
            if Task.isCancelled { break }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                skipped += 1
                processed += 1
                continue
            }
            currentName = Self.displayName(for: asset)
            currentDetail = nil
            let name = currentName ?? identifier
            let started = Date()

            do {
                let outcome = try await importAsset(asset, service: service)
                switch outcome {
                case .uploaded:
                    uploaded += 1
                    ledger.insert(identifier)
                case .alreadyOnServer:
                    alreadyOnServer += 1
                    ledger.insert(identifier)
                case .skipped:
                    skipped += 1
                }
                Diagnostics.log("\(outcome) \(name) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", to: Self.logFile)
                consecutiveFailures = 0
            } catch {
                if Task.isCancelled { break }
                let message = Self.describe(error)
                failures.append(Failure(name: name, message: message))
                ledger.recordFailure(identifier, name: name, message: message)
                Diagnostics.log("FAILED \(name) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(message)", to: Self.logFile)
                consecutiveFailures += 1

                // A run of failures is usually the server or network, not five bad
                // photos. Check before giving up: if it's unreachable, wait for it to
                // come back rather than abandoning the import; if it's fine, the
                // failures are specific to those items, so carry on past them.
                if consecutiveFailures >= 5 && consecutiveFailures % 5 == 0 {
                    if await waitForServer(service) {
                        Diagnostics.log("server reachable after \(consecutiveFailures) failures in a row — continuing", to: Self.logFile)
                    } else {
                        stopReason = "The server stopped responding and didn't come back after a few minutes. Progress is saved — Resume Import picks up from here."
                        break
                    }
                }
                if consecutiveFailures >= 40 {
                    stopReason = "Stopped after 40 failures in a row even though the server is reachable — see the failure list for what's going wrong."
                    break
                }
            }
            processed += 1
            if processed % 10 == 0 { ledger.save() }
        }

        ledger.save()
        currentName = nil
        currentDetail = nil
        phase = Task.isCancelled || stopReason != nil ? .stopped : .finished
        await refreshCounts()
    }

    private func importAsset(_ asset: PHAsset, service: ImmichService) async throws -> Outcome {
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto]
        guard let primary = primaryTypes.lazy.compactMap({ type in resources.first { $0.type == type } }).first else {
            return .skipped
        }

        let createdAt = asset.creationDate ?? Date()
        let modifiedAt = asset.modificationDate ?? createdAt

        // A Live Photo is a still plus a short video. Immich wants the video uploaded
        // first and the still linked to it, otherwise the motion half is lost or
        // shows up as a separate video.
        var options = ImmichService.UploadOptions(isFavorite: asset.isFavorite)
        if asset.mediaType == .image, let video = resources.first(where: { $0.type == .pairedVideo }) {
            let videoResult = try await upload(video, createdAt: createdAt, modifiedAt: modifiedAt, service: service, options: .init())
            options.livePhotoVideoId = videoResult.assetId
        }

        let result = try await upload(primary, createdAt: createdAt, modifiedAt: modifiedAt, service: service, options: options)
        switch result {
        case .created: return .uploaded
        case .duplicate: return .alreadyOnServer
        }
    }

    private func upload(
        _ resource: PHAssetResource,
        createdAt: Date,
        modifiedAt: Date,
        service: ImmichService,
        options: ImmichService.UploadOptions
    ) async throws -> ImmichService.UploadResult {
        // Before fetching anything from iCloud: if the server connection is known to turn
        // away a file this big (and there's no direct address for it), don't download it.
        if let size = Self.fileSize(of: resource) { _ = try service.uploadTarget(forBytes: size) }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("photos-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        currentDetail = "Getting \(resource.originalFilename) from Photos…"
        try await PhotosExporter.export(resource, to: tempURL) { [weak self] fraction in
            Task { @MainActor in
                // PhotoKit only reports progress when it's fetching from iCloud.
                self?.currentDetail = "Downloading \(resource.originalFilename) from iCloud… \(Int(fraction * 100))%"
            }
        }

        currentDetail = "Checking \(resource.originalFilename)…"
        let checksum = try await Task.detached(priority: .utility) { try Self.sha1(of: tempURL) }.value

        currentDetail = "Uploading \(resource.originalFilename)…"
        return try await service.uploadAsset(
            fileURL: tempURL,
            filename: resource.originalFilename,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            checksum: checksum,
            options: options
        )
    }

    // MARK: - Helpers

    /// Newest first, so a limited test run grabs recent items and an interrupted full
    /// run leaves the most recent photos already safe on the server.
    nonisolated private static func scanLibrary(excluding known: Set<String>, since: Date? = nil) -> (total: Int, pending: [String]) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var format = "(mediaType == %d || mediaType == %d)"
        var arguments: [Any] = [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
        if let since {
            format += " && creationDate >= %@"
            arguments.append(since as NSDate)
        }
        options.predicate = NSPredicate(format: format, argumentArray: arguments)
        let result = PHAsset.fetchAssets(with: options)
        var pending: [String] = []
        result.enumerateObjects { asset, _, _ in
            if !known.contains(asset.localIdentifier) { pending.append(asset.localIdentifier) }
        }
        return (result.count, pending)
    }

    /// The original's size in bytes, when PhotoKit will say. `fileSize` isn't a documented
    /// property, so ask only if the object answers to it (an unknown key would raise).
    nonisolated private static func fileSize(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    nonisolated private static func sha1(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func displayName(for asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
    }

    private static func describe(_ error: Error) -> String {
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            let detail = message.map { " — \($0.prefix(200))" } ?? ""
            return "Server responded \(status)\(detail)"
        }
        // These already read as a sentence; PhotoKit and file errors are described by
        // the system.
        return error.localizedDescription
    }

    private static let logFile = "SwiftImmich-import.log"

    /// True once the server answers (immediately if it already does); waits up to about
    /// five minutes for it to come back, checking every 15 seconds, and false if it
    /// doesn't or the import was stopped meanwhile.
    private func waitForServer(_ service: ImmichService) async -> Bool {
        var request = URLRequest(url: service.apiURL.appendingPathComponent("server/ping"))
        request.timeoutInterval = 10
        for attempt in 0..<20 {
            if Task.isCancelled { return false }
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            currentDetail = "Can't reach the server — waiting for it to come back… (\(attempt + 1))"
            try? await Task.sleep(for: .seconds(15))
        }
        return false
    }
}

private extension ImmichService.UploadResult {
    var assetId: String {
        switch self {
        case .created(let id), .duplicate(let id): return id
        }
    }
}

/// Streams one Photos resource to a file, downloading it from iCloud first if it
/// isn't stored on this Mac. Uses the request-based API (rather than `writeData`) so
/// an in-flight iCloud download can actually be cancelled when the user hits Stop.
enum PhotosExporter {
    private final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID = PHInvalidAssetResourceDataRequestID
        private var writeError: Error?
        private var cancelled = false

        func set(requestID id: PHAssetResourceDataRequestID) { lock.withLock { requestID = id } }
        func recordWriteError(_ error: Error) { lock.withLock { if writeError == nil { writeError = error } } }
        func markCancelled() -> PHAssetResourceDataRequestID { lock.withLock { cancelled = true; return requestID } }
        var snapshot: (writeError: Error?, cancelled: Bool) { lock.withLock { (writeError, cancelled) } }
    }

    static func export(
        _ resource: PHAssetResource,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let state = RequestState()
        let manager = PHAssetResourceManager.default()

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        do { try handle.write(contentsOf: data) } catch { state.recordWriteError(error) }
                    },
                    completionHandler: { error in
                        try? handle.close()
                        let (writeError, cancelled) = state.snapshot
                        if let error {
                            continuation.resume(throwing: cancelled ? CancellationError() : error)
                        } else if let writeError {
                            continuation.resume(throwing: writeError)
                        } else {
                            continuation.resume()
                        }
                    }
                )
                state.set(requestID: id)
                if Task.isCancelled { manager.cancelDataRequest(state.markCancelled()) }
            }
        } onCancel: {
            manager.cancelDataRequest(state.markCancelled())
        }
    }
}

/// Remembers which Photos items have already been copied, so a stopped or repeated
/// import picks up where it left off instead of re-downloading everything from
/// iCloud. (The server would still de-duplicate by checksum, but only after the
/// slow part — fetching the original — had already been repeated.)
struct ImportLedger {
    struct FailureRecord: Codable {
        var name: String
        var message: String
        var attempts: Int
        var lastAttempt: Date
    }

    private struct Stored: Codable {
        var imported: [String]
        var failed: [String: FailureRecord]
    }

    private(set) var identifiers: Set<String>
    /// Items that failed on an earlier run, by Photos identifier.
    private(set) var failed: [String: FailureRecord] = [:]
    private let fileURL: URL?

    init(serverIdentity: String? = nil) {
        guard let serverIdentity else {
            identifiers = []
            fileURL = nil
            return
        }
        let key = Insecure.SHA1.hash(data: Data(serverIdentity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftImmich", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photos-import-\(key).json")
        fileURL = url
        identifiers = []
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode(Stored.self, from: data) {
            identifiers = Set(stored.imported)
            failed = stored.failed
        } else if let legacy = try? decoder.decode([String].self, from: data) {
            // The first version of this file was a bare list of imported identifiers.
            identifiers = Set(legacy)
        }
    }

    mutating func insert(_ identifier: String) {
        identifiers.insert(identifier)
        failed[identifier] = nil
    }

    mutating func recordFailure(_ identifier: String, name: String, message: String) {
        failed[identifier] = FailureRecord(
            name: name,
            message: message,
            attempts: (failed[identifier]?.attempts ?? 0) + 1,
            lastAttempt: Date()
        )
    }

    func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(imported: Array(identifiers), failed: failed)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
