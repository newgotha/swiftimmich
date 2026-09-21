import AppKit
import ImmichAPI
import SwiftUI

/// A personal album order for the sidebar and Albums page. Immich has no album ordering of
/// its own, so it's kept on this Mac: albums you've placed come first in your order, and any
/// new ones follow in the order the server gives them.
enum AlbumOrder {
    static let key = "albumOrder"

    static func apply(_ savedIds: [String], to albums: [Components.Schemas.AlbumResponseDto]) -> [Components.Schemas.AlbumResponseDto] {
        let byId = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = savedIds.compactMap { byId[$0] }
        let placedIds = Set(placed.map(\.id))
        return placed + albums.filter { !placedIds.contains($0.id) }
    }

    /// The ids in their new order after dragging `source` rows to `destination` (SwiftUI's `onMove`).
    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        var result = ids
        let moving = source.sorted().map { result[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted().reversed() { result.remove(at: index) }
        result.insert(contentsOf: moving, at: destination - before)
        return result
    }

    static var saved: [String] {
        guard let data = UserDefaults.standard.data(forKey: key), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    static func save(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

extension ImmichService {
    struct ArchivePlan {
        /// The photos in each zip file; Immich splits a big album into several.
        let archives: [[String]]
        let totalBytes: Int
    }

    private func jsonRequest(_ path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&request)
        return request
    }

    private static func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        var message: String?
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { message = json["message"] as? String }
        throw ImmichServiceError.requestFailed(statusCode: http.statusCode, message: message)
    }

    /// How Immich would pack an album into zip files (it splits at about 4 GB each).
    func archivePlan(forAlbum albumId: String) async throws -> ArchivePlan {
        let request = try jsonRequest("download/info", body: ["albumId": albumId, "archiveSize": 4_000_000_000])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let archives = json["archives"] as? [[String: Any]] else {
            throw ImmichServiceError.requestFailed(statusCode: 200, message: "unexpected reply")
        }
        return ArchivePlan(
            archives: archives.map { ($0["assetIds"] as? [String]) ?? [] },
            totalBytes: (json["totalSize"] as? Int) ?? 0
        )
    }

    /// Downloads one zip of the given photos to a temporary file and returns it.
    func downloadArchive(assetIds: [String]) async throws -> URL {
        let request = try jsonRequest("download/archive", body: ["assetIds": assetIds])
        let (file, response) = try await URLSession.shared.download(for: request)
        do { try Self.check(response) } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }
}

extension TransferCenter {
    /// Saves a whole album as zip file(s): one asks for a name, several ask for a folder.
    func downloadAlbum(_ album: Components.Schemas.AlbumResponseDto, service: ImmichService) {
        guard !isRunning else { return }
        beginAlbumDownload(title: "Preparing “\(album.albumName)”")
        setAlbumTask(Task {
            do {
                let plan = try await service.archivePlan(forAlbum: album.id)
                guard !plan.archives.isEmpty else {
                    finishAlbumDownload("“\(album.albumName)” has nothing to download.")
                    return
                }
                let safeName = album.albumName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let destinations = try Self.chooseDestinations(count: plan.archives.count, name: safeName, totalBytes: plan.totalBytes)
                guard let destinations else { finishAlbumDownload(nil); return }

                setAlbumProgress(total: plan.archives.count)
                for (index, ids) in plan.archives.enumerated() {
                    try Task.checkCancellation()
                    setAlbumCurrent(plan.archives.count > 1 ? "Part \(index + 1) of \(plan.archives.count)" : album.albumName)
                    let temp = try await service.downloadArchive(assetIds: ids)
                    try? FileManager.default.removeItem(at: destinations[index])
                    try FileManager.default.moveItem(at: temp, to: destinations[index])
                    setAlbumProgress(completed: index + 1)
                }
                finishAlbumDownload("Saved “\(album.albumName)” as \(plan.archives.count == 1 ? "a zip file" : "\(plan.archives.count) zip files").")
            } catch {
                if error is CancellationError { finishAlbumDownload(nil); return }
                addAlbumFailure(error)
                finishAlbumDownload("Couldn't download the album.")
            }
        })
    }

    @MainActor
    private static func chooseDestinations(count: Int, name: String, totalBytes: Int) throws -> [URL]? {
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        if count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(name).zip"
            panel.message = "The album is about \(size)."
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return [url]
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "The album is about \(size) and will be saved as \(count) zip files."
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        return (1...count).map { folder.appendingPathComponent("\(name) (\($0)).zip") }
    }
}


/// Asks for a new description for the album in `selection.pendingDescribeAlbum`.
struct AlbumDescriptionPrompt: ViewModifier {
    @ObservedObject var selection: GridSelection
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: selection.pendingDescribeAlbum?.id) { _, _ in
                if let album = selection.pendingDescribeAlbum { text = album.description }
            }
            .alert("Album Description", isPresented: Binding(
                get: { selection.pendingDescribeAlbum != nil },
                set: { if !$0 { selection.pendingDescribeAlbum = nil } }
            )) {
                TextField("Description", text: $text)
                Button("Save") {
                    guard let album = selection.pendingDescribeAlbum else { return }
                    selection.pendingDescribeAlbum = nil
                    let value = text
                    Task { await selection.describe(album, as: value) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }
}
