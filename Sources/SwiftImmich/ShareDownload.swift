import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches a file from the server into a properly named temporary file, ready to hand
/// to the system share sheet — which wants a real file (with a sensible name and
/// extension) rather than raw bytes.
enum ShareDownload {
    enum Failure: LocalizedError {
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .badStatus(let status): return "The server responded with status \(status)."
            }
        }
    }

    /// - Parameters:
    ///   - originalFileName: The asset's original name, used for the base name (and as
    ///     the extension fallback).
    ///   - sniffImageType: For photos, work the extension out from the downloaded
    ///     bytes. An edited photo is re-rendered by the server and can be a different
    ///     format from the original (an edited HEIC arrives as a JPEG), so trusting the
    ///     original's extension would hand recipients a file whose name lies about it.
    static func fetch(_ request: URLRequest, originalFileName: String, sniffImageType: Bool) async throws -> URL {
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: downloaded)
            throw Failure.badStatus(http.statusCode)
        }

        let original = originalFileName as NSString
        let baseName = original.deletingPathExtension.isEmpty ? "Photo" : original.deletingPathExtension
        var fileExtension = original.pathExtension
        if sniffImageType, let sniffed = imageExtension(of: downloaded) {
            fileExtension = sniffed
        }

        // Its own folder per share, so two photos with the same name can't collide.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftImmich-Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)")
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private static func imageExtension(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return nil }
        // UTType prefers "jpeg"; "jpg" is what people and most software expect.
        if type.conforms(to: .jpeg) { return "jpg" }
        return type.preferredFilenameExtension
    }
}
