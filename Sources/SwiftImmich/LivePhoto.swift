import AVFoundation
import AVKit
import SwiftUI

/// Plays a Live Photo's motion clip once, with no controls, and reports when it ends.
struct LiveClipView: NSViewRepresentable {
    let request: URLRequest
    var onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false

        let headers = request.allHTTPHeaderFields ?? [:]
        if let url = request.url {
            // Same header trick as VideoPlayerView: AVPlayer has no first-class way to
            // send the API key.
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            view.player = player
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { _ in onFinished() }
            player.play()
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// The "LIVE" control laid over a Live Photo in the viewer: hover it (or click it) to
/// play the moment around the photo. It's drawn at the photo's own size, with the pill
/// pinned to the top-right corner — the layout must not change while playing, or the pill
/// moves out from under the pointer and playback flickers on and off.
struct LivePhotoLayer: View {
    let service: ImmichService
    let videoId: String
    /// The size the photo is drawn at.
    let size: CGSize

    @State private var isPlaying = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fills the photo's area without catching clicks meant for the photo itself.
            Color.clear.allowsHitTesting(false)

            if isPlaying {
                LiveClipView(request: service.videoPlaybackRequest(assetId: videoId)) { isPlaying = false }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            HStack(spacing: 4) {
                Image(systemName: "livephoto")
                Text("LIVE")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(isPlaying ? 0.7 : 0.5), in: Capsule())
            .padding(12)
            .contentShape(Capsule())
            .onHover { inside in withAnimation(.easeInOut(duration: 0.2)) { isPlaying = inside } }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isPlaying.toggle() } }
            .help("Hover to play")
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // A new photo starts from rest.
        .id(videoId)
    }
}

/// Slideshow preferences and full-screen handling.
enum Slideshow {
    static let secondsKey = "slideshowSeconds"
    static let fullScreenKey = "slideshowFullScreen"

    static var isFullScreen: Bool {
        NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
    }

    static func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }
}
