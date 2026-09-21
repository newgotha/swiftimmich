import AVFoundation
import CoreImage
import SwiftUI
import XCTest
@testable import SwiftImmich

/// Makes a small real H.264 movie whose colour changes steadily, with a keyframe every second.
enum TestVideo {
    static func make(seconds: Int, fps: Int = 30, width: Int = 96, height: Int = 64) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-video-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: fps, AVVideoAllowFrameReorderingKey: false],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = seconds * fps
        for frame in 0..<total {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let progress = CGFloat(frame) / CGFloat(total)
            context.setFillColor(CGColor(red: progress, green: 1 - progress, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }
        return url
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }
}

final class TrimRangeTests: XCTestCase {
    func testAFullClipStartsUncut() {
        let range = TrimRange(duration: 10)
        XCTAssertEqual(range.start, 0); XCTAssertEqual(range.end, 10); XCTAssertEqual(range.length, 10)
        XCTAssertTrue(range.isFullClip)
    }

    func testTheHandlesStayInsideTheClipAndNeverCross() {
        var range = TrimRange(duration: 10)
        range.setStart(-5); XCTAssertEqual(range.start, 0)
        range.setEnd(99); XCTAssertEqual(range.end, 10)
        range.setStart(9.9); XCTAssertEqual(range.start, 10 - TrimRange.minimumLength, accuracy: 0.0001, "the start can't reach the end")
        range.setEnd(0); XCTAssertEqual(range.end, range.start + TrimRange.minimumLength, accuracy: 0.0001, "the end can't reach the start")
        XCTAssertFalse(range.isFullClip)
    }

    func testAShortClipIsHandledSafely() {
        var range = TrimRange(duration: 0.3)
        range.setStart(0.2); range.setEnd(0.1)
        XCTAssertGreaterThanOrEqual(range.start, 0)
        XCTAssertLessThanOrEqual(range.end, 0.3)
        XCTAssertGreaterThanOrEqual(range.length, 0)
        XCTAssertEqual(TrimRange(duration: -4).duration, 0)
    }

    func testTheRangeConvertsToMediaTime() {
        var range = TrimRange(duration: 20)
        range.setStart(2.5); range.setEnd(12)
        XCTAssertEqual(range.cmRange.start.seconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(range.cmRange.duration.seconds, 9.5, accuracy: 0.001)
    }

    func testTimesAreReadable() {
        XCTAssertEqual(VideoClock.text(5.34), "0:05.3")
        XCTAssertEqual(VideoClock.text(65.0), "1:05.0")
        XCTAssertEqual(VideoClock.text(3725), "1:02:05")
        XCTAssertEqual(VideoClock.text(-3), "0:00.0")
    }
}

final class VideoExportTests: XCTestCase {
    private var made: [URL] = []
    override func tearDown() { for url in made { try? FileManager.default.removeItem(at: url) }; made = [] }

    private func video(seconds: Int) async throws -> URL {
        let url = try await TestVideo.make(seconds: seconds)
        made.append(url)
        return url
    }

    func testTheGeneratedTestVideoIsReal() async throws {
        let url = try await video(seconds: 8)
        let length = try await TestVideo.duration(of: url)
        XCTAssertEqual(length, 8, accuracy: 0.1)
    }

    func testAnExactCutHasTheRequestedLength() async throws {
        let source = try await video(seconds: 8)
        var range = TrimRange(duration: 8)
        range.setStart(2.4); range.setEnd(5.4)
        let out = try await VideoExporter.export(source: source, range: range, mode: .exact)
        made.append(out)
        let length = try await TestVideo.duration(of: out)
        XCTAssertEqual(length, 3.0, accuracy: 0.15)
        XCTAssertEqual(out.pathExtension, "mov")
        let asset = AVURLAsset(url: out)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        XCTAssertEqual(size?.width, 96); XCTAssertEqual(size?.height, 64)
    }

    func testAFastCutStartsAtAKeyframeAndKeepsTheEnd() async throws {
        let source = try await video(seconds: 8)
        var range = TrimRange(duration: 8)
        range.setStart(2.4); range.setEnd(6)
        let out = try await VideoExporter.export(source: source, range: range, mode: .fast)
        made.append(out)
        let length = try await TestVideo.duration(of: out)
        XCTAssertGreaterThan(length, 3.4, "at least what was asked for")
        XCTAssertLessThan(length, 4.7, "no more than a keyframe interval extra")
    }

    func testProgressIsReportedAndFinishesAtOne() async throws {
        let source = try await video(seconds: 4)
        let seen = ProgressBox()
        let out = try await VideoExporter.export(source: source, range: TrimRange(duration: 4), mode: .exact) { seen.add($0) }
        made.append(out)
        XCTAssertEqual(seen.last, 1)
    }

    func testAVideoThatCantBeReadFailsCleanly() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        try Data("nothing here".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        do {
            _ = try await VideoExporter.export(source: bogus, range: TrimRange(duration: 5), mode: .fast)
            XCTFail("expected a failure")
        } catch is VideoExporter.Failure {
        } catch {
            XCTFail("expected our own failure, got \(error)")
        }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
}

final class VideoFramesTests: XCTestCase {
    private var url: URL?
    override func tearDown() { if let url { try? FileManager.default.removeItem(at: url) } }

    private func brightnessOfRed(_ image: CGImage) -> Double {
        let ci = CIImage(cgImage: image)
        var pixel = [UInt8](repeating: 0, count: 4)
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])!
        ImageRenderer.context.render(filter.outputImage!, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: ImageRenderer.sRGB)
        return Double(pixel[0])
    }

    func testTheFilmstripHasAPictureForEachSlice() async throws {
        let file = try await TestVideo.make(seconds: 6); url = file
        let frames = await VideoFrames.filmstrip(of: AVURLAsset(url: file), count: 6, height: 40)
        XCTAssertEqual(frames.count, 6)
        XCTAssertTrue(frames.allSatisfy { $0 != nil })
        XCTAssertLessThanOrEqual(frames.compactMap { $0?.height }.max() ?? 0, 40)
        // The colour moves steadily through the clip, so the first and last slices differ.
        XCTAssertLessThan(brightnessOfRed(try XCTUnwrap(frames.first ?? nil)), brightnessOfRed(try XCTUnwrap(frames.last ?? nil)))
    }

    func testAnExactFrameComesBackAtFullSize() async throws {
        let file = try await TestVideo.make(seconds: 6); url = file
        let asset = AVURLAsset(url: file)
        let early = try await VideoFrames.frame(of: asset, at: 0.5)
        let late = try await VideoFrames.frame(of: asset, at: 5.5)
        XCTAssertEqual(early.width, 96); XCTAssertEqual(early.height, 64)
        XCTAssertLessThan(brightnessOfRed(early), brightnessOfRed(late) - 60)
        let jpeg = try XCTUnwrap(VideoFrames.jpegData(from: late))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]), "a real JPEG")
    }

    func testSpeedIsSetOnThePlayerAndTheNextPlay() {
        let player = AVPlayer()
        let controller = VideoPlaybackController()
        controller.attach(player)
        controller.speed = .double
        XCTAssertEqual(player.defaultRate, 2)
        controller.speed = .half
        XCTAssertEqual(player.defaultRate, 0.5)
        XCTAssertEqual(VideoSpeed.normal.title, "Normal speed")
        XCTAssertEqual(VideoSpeed.oneAndAHalf.title, "1.5×")
    }
}

/// The trim editor plays a video and draws a filmstrip; it must settle rather than redraw forever.
@MainActor
final class TrimEditorSettlesTests: XCTestCase {
    func testTheTrimEditorRendersAndGoesQuiet() async throws {
        _ = NSApplication.shared
        let file = try await TestVideo.make(seconds: 6)
        // Like the app, the file lives in its own folder, which the editor removes when it closes.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("clip.mov")
        try FileManager.default.moveItem(at: file, to: moved)
        defer { try? FileManager.default.removeItem(at: folder) }

        var saved = 0
        let editor = VideoTrimView(
            session: TrimSession(fileURL: moved, duration: 6, title: "clip.mov"),
            save: { _, _, _ in saved += 1 },
            close: {}
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: editor))
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: .seconds(2.5))   // the filmstrip renders
        func cpu() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        }
        let before = cpu()
        try await Task.sleep(for: .seconds(2))
        let busy = (cpu() - before) / 2
        XCTAssertLessThan(busy, 0.4, "the editor keeps the main thread busy (\(Int(busy * 100))%) with nothing happening")
        XCTAssertEqual(saved, 0, "drawing the editor saves nothing by itself")
    }
}
