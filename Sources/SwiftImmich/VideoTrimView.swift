import AVKit
import SwiftUI

/// A downloaded copy of a video, ready to be cut.
struct TrimSession: Identifiable {
    let id = UUID()
    let fileURL: URL
    let duration: Double
    let title: String
}

enum TrimStage: Sendable {
    case cutting(Double)
    case uploading
}

/// The trim editor: a preview, a filmstrip with a handle at each end, and Save.
struct VideoTrimView: View {
    let session: TrimSession
    /// Cuts the range and uploads the result as a new video.
    let save: (TrimRange, VideoExporter.Mode, @escaping @Sendable (TrimStage) -> Void) async throws -> Void
    let close: () -> Void

    @State private var range: TrimRange
    @State private var exact = false
    @State private var player: AVPlayer
    @State private var frames: [CGImage?] = []
    @State private var stage: TrimStage?
    @State private var errorText: String?
    @State private var work: Task<Void, Never>?
    @State private var boundary: Any?

    private let stripHeight: CGFloat = 56
    private let handleWidth: CGFloat = 14

    init(session: TrimSession, save: @escaping (TrimRange, VideoExporter.Mode, @escaping @Sendable (TrimStage) -> Void) async throws -> Void, close: @escaping () -> Void) {
        self.session = session
        self.save = save
        self.close = close
        _range = State(initialValue: TrimRange(duration: session.duration))
        _player = State(initialValue: AVPlayer(url: session.fileURL))
    }

    private var isBusy: Bool { stage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim “\(session.title)”")
                .font(.headline)

            TrimPlayer(player: player)
                .frame(minWidth: 560, minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            filmstrip

            HStack {
                Text("\(VideoClock.text(range.start)) – \(VideoClock.text(range.end))")
                    .font(.callout.monospacedDigit())
                Text("\(VideoClock.text(range.length)) of \(VideoClock.text(range.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    playSelection()
                } label: {
                    Label("Play Selection", systemImage: "play.fill")
                }
                .disabled(isBusy)
            }

            Toggle("Exact cut (slower — the video is compressed again)", isOn: $exact)
                .toggleStyle(.checkbox)
                .disabled(isBusy)
            Text(exact
                 ? "Cuts exactly where the handles are."
                 : "Cuts at the nearest keyframe, so the start can be up to a second early. Quick, and nothing is recompressed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let stage {
                HStack(spacing: 10) {
                    switch stage {
                    case .cutting(let progress):
                        ProgressView(value: progress).frame(width: 220)
                        Text("Cutting…").foregroundStyle(.secondary)
                    case .uploading:
                        ProgressView().controlSize(.small)
                        Text("Uploading…").foregroundStyle(.secondary)
                    }
                }
            }
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { work?.cancel(); close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save as New Video") { perform() }
                    .buttonStyle(HoverProminentStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || range.isFullClip)
                    .help(range.isFullClip ? "Move a handle to choose what to keep" : "The original video is kept")
            }
        }
        .padding(20)
        .frame(minWidth: 600)
        .task { frames = await VideoFrames.filmstrip(of: AVURLAsset(url: session.fileURL), count: 14, height: stripHeight * 2) }
        .onDisappear {
            player.pause()
            if let boundary { player.removeTimeObserver(boundary) }
            // Its own folder from the download, so it can all go.
            try? FileManager.default.removeItem(at: session.fileURL.deletingLastPathComponent())
        }
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = width * range.start / max(range.duration, 0.001)
            let endX = width * range.end / max(range.duration, 0.001)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Group {
                            if let image = frames[index] {
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.gray.opacity(0.3)
                            }
                        }
                        .frame(width: width / CGFloat(max(frames.count, 1)), height: stripHeight)
                        .clipped()
                    }
                }
                .frame(width: width, height: stripHeight, alignment: .leading)
                .background(Color.gray.opacity(0.2))

                Rectangle().fill(Color.black.opacity(0.6)).frame(width: startX, height: stripHeight)
                Rectangle().fill(Color.black.opacity(0.6)).frame(width: max(width - endX, 0), height: stripHeight).offset(x: endX)
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(endX - startX, 0), height: stripHeight)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle(at: startX - handleWidth / 2, label: "Start of the part to keep")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        range.setStart(Double(value.location.x / width) * range.duration)
                        seek(to: range.start)
                    })
                handle(at: endX - handleWidth / 2, label: "End of the part to keep")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { value in
                        range.setEnd(Double(value.location.x / width) * range.duration)
                        seek(to: max(range.end - 0.05, range.start))
                    })
            }
            .coordinateSpace(name: "strip")
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: stripHeight)
        .disabled(isBusy)
    }

    private func handle(at x: CGFloat, label: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: stripHeight)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 22))
            .offset(x: x)
            .accessibilityLabel(label)
            .accessibilityValue(VideoClock.text(label.hasPrefix("Start") ? range.start : range.end))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                if label.hasPrefix("Start") { range.setStart(range.start + step) } else { range.setEnd(range.end + step) }
            }
    }

    // MARK: - Playing and saving

    private func seek(to seconds: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays from the start handle and stops at the end handle.
    private func playSelection() {
        if let boundary { player.removeTimeObserver(boundary) }
        let end = CMTime(seconds: range.end, preferredTimescale: 600)
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [player] in player.pause() }
        player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    private func perform() {
        player.pause()
        errorText = nil
        stage = .cutting(0)
        let chosen = range
        let mode: VideoExporter.Mode = exact ? .exact : .fast
        work = Task {
            do {
                try await save(chosen, mode) { newStage in
                    Task { @MainActor in stage = newStage }
                }
                close()
            } catch is CancellationError {
                stage = nil
            } catch {
                errorText = error.localizedDescription
                stage = nil
            }
        }
    }
}

/// A plain player with the standard controls, for the trim editor.
private struct TrimPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
