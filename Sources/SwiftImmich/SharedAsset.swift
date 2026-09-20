import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the system share sheet is handed for a photo or video on the server.
///
/// Lazy on purpose: `ShareLink` opens its menu immediately and only asks for the
/// file's contents once a destination is chosen, so nothing is downloaded (and a
/// large video doesn't stall the button) unless the user actually shares it.
///
/// A `Transferable` declares its content type statically, so a photo and a video need
/// different representations — but a multi-selection can contain both, so one type
/// carries both and each is only offered for the kind of asset it actually is.
struct SharedAssetFile: Transferable {
    let service: ImmichService
    let assetId: String
    let isImage: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try await item.service.downloadForSharing(assetId: item.assetId, isImage: true))
        }
        .exportingCondition { $0.isImage }

        FileRepresentation(exportedContentType: .movie) { item in
            SentTransferredFile(try await item.service.downloadForSharing(assetId: item.assetId, isImage: false))
        }
        .exportingCondition { !$0.isImage }
    }
}

extension ImmichService {
    /// Downloads what the user is looking at. For photos that's the edited render
    /// (`edited: true`), so a photo cropped or rotated in Immich shares as it appears;
    /// unedited photos just come back as the original. Videos have no edits, and
    /// asking for an edited render of one is exactly the request that broke video
    /// thumbnails earlier, so it isn't sent.
    func downloadForSharing(assetId: String, isImage: Bool) async throws -> URL {
        let info = try await fetchAssetInfo(assetId: assetId)
        return try await ShareDownload.fetch(
            originalFileRequest(assetId: assetId, edited: isImage),
            originalFileName: info.originalFileName,
            sniffImageType: isImage
        )
    }
}
