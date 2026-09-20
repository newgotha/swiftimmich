import Foundation
import OpenAPIRuntime

/// Immich doesn't consistently format every date-time field the same way — asset
/// timestamps carry fractional seconds, but EXIF-derived fields (dateTimeOriginal,
/// modifyDate) have shown up without them, or without a trailing offset at all.
/// This tries progressively looser formats instead of failing the whole decode.
struct LenientDateTranscoder: DateTranscoder {
    private let withFractionalSeconds = ISO8601DateFormatter()
    private let withoutFractionalSeconds = ISO8601DateFormatter()
    private let fallback: DateFormatter

    init() {
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        fallback = DateFormatter()
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fallback.timeZone = TimeZone(identifier: "UTC")
        fallback.locale = Locale(identifier: "en_US_POSIX")
    }

    func encode(_ date: Date) throws -> String {
        withFractionalSeconds.string(from: date)
    }

    func decode(_ dateString: String) throws -> Date {
        if let date = withFractionalSeconds.date(from: dateString) { return date }
        if let date = withoutFractionalSeconds.date(from: dateString) { return date }
        if let date = fallback.date(from: dateString) { return date }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Unrecognized date format: \(dateString)")
        )
    }
}
