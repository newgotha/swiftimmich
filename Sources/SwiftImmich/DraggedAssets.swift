import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Photos being dragged out of a grid. Two audiences:
/// - inside the app (e.g. onto an album in the sidebar): carried as text with a private
///   prefix, so dropping something unrelated on an album is rejected rather than misread;
/// - other apps and Finder: the photo itself, downloaded only once it's actually dropped.
///   One photo drops as a file; several drop as a folder holding them all.
struct DraggedAssets: Transferable {
    struct Item {
        let id: String
        let isImage: Bool
    }

    private static let prefix = "swiftimmich-assets:"
    let items: [Item]
    /// Nil for a payload read back from a drop (only the ids matter there).
    let service: ImmichService?

    var ids: [String] { items.map(\.id) }

    init(items: [Item], service: ImmichService?) {
        self.items = items
        self.service = service
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { dragged in
            guard let service = dragged.service, let item = dragged.items.first else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(try await service.downloadForSharing(assetId: item.id, isImage: true))
        }
        .exportingCondition { $0.items.count == 1 && $0.items[0].isImage && $0.service != nil }

        FileRepresentation(exportedContentType: .movie) { dragged in
            guard let service = dragged.service, let item = dragged.items.first else { throw CocoaError(.fileNoSuchFile) }
            return SentTransferredFile(try await service.downloadForSharing(assetId: item.id, isImage: false))
        }
        .exportingCondition { $0.items.count == 1 && !$0.items[0].isImage && $0.service != nil }

        FileRepresentation(exportedContentType: .folder) { dragged in
            guard let service = dragged.service else { throw CocoaError(.fileNoSuchFile) }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftImmich-Share", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("\(dragged.items.count) Photos", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in dragged.items {
                let file = try await service.downloadForSharing(assetId: item.id, isImage: item.isImage)
                var destination = folder.appendingPathComponent(file.lastPathComponent)
                var counter = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    let base = file.deletingPathExtension().lastPathComponent
                    let ext = file.pathExtension
                    destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                    counter += 1
                }
                try FileManager.default.moveItem(at: file, to: destination)
            }
            return SentTransferredFile(folder)
        }
        .exportingCondition { $0.items.count > 1 && $0.service != nil }

        ProxyRepresentation(
            exporting: { prefix + $0.ids.joined(separator: ",") },
            importing: { text in
                guard text.hasPrefix(prefix) else { throw CocoaError(.fileReadCorruptFile) }
                let ids = text.dropFirst(prefix.count).split(separator: ",").map(String.init)
                return DraggedAssets(items: ids.map { Item(id: $0, isImage: true) }, service: nil)
            }
        )
    }
}
