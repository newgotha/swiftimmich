import AVFoundation
import AVKit
import CoreImage
import Foundation

/// The part of a clip to keep, in seconds.
struct TrimRange: Equatable {
    static let minimumLength = 0.5

    let duration: Double
    private(set) var start = 0.0
    private(set) var end: Double

    init(duration: Double) {
        self.duration = max(duration, 0)
        end = self.duration
    }

    mutating func setStart(_ seconds: Double) {
        start = min(max(seconds, 0), max(end - Self.minimumLength, 0))
    }

    mutating func setEnd(_ seconds: Double) {
        end = max(min(seconds, duration), min(start + Self.minimumLength, duration))
    }

    var length: Double { end - start }
    /// Nothing has been cut off.
    var isFullClip: Bool { start < 0.05 && end > duration - 0.05 }

    var cmRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
    }
}

enum VideoSpeed: Double, CaseIterable, Identifiable {
    case half = 0.5, normal = 1, oneAndAHalf = 1.5, double = 2

    var id: Double { rawValue }
    var title: String { self == .normal ? "Normal speed" : "\(rawValue.formatted())×" }
}

enum VideoClock {
    /// "0:05.3", or "1:02:05" style once past an hour.
    static func text(_ seconds: Double) -> String {
        let total = max(seconds, 0)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = total - Double(Int(total) / 60 * 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, Int(total) % 60) }
        return String(format: "%d:%04.1f", minutes, secs)
    }
}

enum VideoExporter {
    enum Mode {
        /// Copies the video as it is, cutting at the nearest keyframes: quick and lossless, but the
        /// start can be up to a second or so off.
        case fast
        /// Re-encodes, so the cut is exact. Slower, and the file is compressed again.
        case exact
    }

    enum Failure: LocalizedError {
        case cannotExport(String)

        var errorDescription: String? {
            switch self {
            case .cannotExport(let reason): return "Couldn't cut the video: \(reason)"
            }
        }
    }

    /// Writes the chosen part of `source` to a new file and returns it. `progress` gets 0...1.
    static func export(source: URL, range: TrimRange, mode: Mode, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let preset = mode == .fast ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.cannotExport("this video can't be exported on this Mac.")
        }
        let isMov = source.pathExtension.lowercased() == "mov"
        let fileType: AVFileType = isMov && session.supportedFileTypes.contains(.mov) ? .mov : .mp4
        guard session.supportedFileTypes.contains(fileType) else {
            throw Failure.cannotExport("the video's format isn't supported.")
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftImmich-Trim/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent("\(base)-trimmed.\(fileType == .mov ? "mov" : "mp4")")

        session.outputURL = output
        session.outputFileType = fileType
        session.timeRange = range.cmRange
        session.shouldOptimizeForNetworkUse = true

        nonisolated(unsafe) let box = session
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(box.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { ticker.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.exportAsynchronously {
                    switch box.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: Failure.cannotExport(box.error?.localizedDescription ?? "unknown error"))
                    }
                }
            }
        } onCancel: {
            box.cancelExport()
        }
        progress(1)
        return output
    }
}

enum VideoFrames {
    /// A row of small pictures spread across the clip, for the trim bar. Frames that can't be read are nil.
    static func filmstrip(of asset: AVAsset, count: Int, height: CGFloat) async -> [CGImage?] {
        guard let duration = try? await asset.load(.duration).seconds, duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frames: [CGImage?] = []
        for index in 0..<count {
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            let picture = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            frames.append(picture)
        }
        return frames
    }

    /// One exact frame at full size.
    static func frame(of asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)).image
    }

    static func jpegData(from image: CGImage, quality: Double = 0.92) -> Data? {
        ImageRenderer.jpegData(from: CIImage(cgImage: image), quality: quality)
    }
}

/// Lets the viewer's own controls reach the player that `VideoPlayerView` creates.
final class VideoPlaybackController {
    private(set) weak var player: AVPlayer?
    var speed: VideoSpeed = .normal { didSet { apply() } }

    func attach(_ player: AVPlayer) {
        self.player = player
        apply()
    }

    /// Sets the speed pressing play uses, and changes it right away if already playing.
    private func apply() {
        guard let player else { return }
        player.defaultRate = Float(speed.rawValue)
        if player.timeControlStatus == .playing { player.rate = Float(speed.rawValue) }
    }

    var currentSeconds: Double { player?.currentTime().seconds ?? 0 }
    var currentAsset: AVAsset? { player?.currentItem?.asset }
}
