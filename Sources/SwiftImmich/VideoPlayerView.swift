import AVFoundation
import AVKit
import SwiftUI

/// Wraps AVPlayer so it can play Immich's video endpoint, which requires the
/// x-api-key header AVPlayer has no first-class way to attach except through
/// AVURLAsset's HTTP header options.
///
/// Drives AppKit's `AVPlayerView` directly via `NSViewRepresentable` rather than
/// AVKit's SwiftUI `VideoPlayer` — the latter fatally crashes this SDK's beta Swift
/// runtime (`getSuperclassMetadata` deep inside `_AVKit_SwiftUI`) essentially any time
/// its generic view metadata gets resolved, which was taking down browsing anywhere in
/// the app that could reach a view containing it, not just while actually playing.
struct VideoPlayerView: NSViewRepresentable {
    let request: URLRequest

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard let url = request.url, context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        let headers = request.allHTTPHeaderFields ?? [:]
        // AVURLAssetHTTPHeaderFieldsKey is no longer declared in this SDK's headers,
        // even though the underlying option is still honored by AVURLAsset — pass its
        // known string value directly rather than the (now-unavailable) named constant.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        nsView.player = player
        player.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
    }
}
