import Photos
import SwiftUI

/// Tells the app when the Photos library changes (a new photo taken, or one arriving
/// from iCloud).
final class PhotoLibraryWatcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?()
    }
}

/// Imports new photos from the Photos library automatically while the app is open, when
/// "Import new photos automatically" is on: shortly after Photos changes, and whenever
/// the app comes to the front.
///
/// It only covers photos taken from the moment it was switched on, so turning it on
/// never quietly starts uploading an entire library — the manual import is for the
/// backlog. A modifier of its own because ContentView's body is at the type-checker limit.
struct AutoImport: ViewModifier {
    static let enabledKey = "autoImportPhotos"
    static let sinceKey = "autoImportSince"
    /// Pausing keeps automatic import switched on but stops it running (from the menu bar).
    static let pausedKey = "autoImportPaused"

    let service: ImmichService?
    @ObservedObject var importer: PhotosImporter

    @AppStorage(AutoImport.enabledKey) private var enabled = false
    @AppStorage(AutoImport.sinceKey) private var since = 0.0
    @AppStorage(AutoImport.pausedKey) private var paused = false
    @State private var watcher = PhotoLibraryWatcher()
    @State private var debounce: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task(id: "\(enabled)|\(service?.apiURL.absoluteString ?? "")|\(importer.authorization.rawValue)") {
                await setUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                schedule(after: 3)
            }
            .onChange(of: paused) { _, isPaused in
                if isPaused { debounce?.cancel(); importer.stop() } else { schedule(after: 1) }
            }
    }

    private func setUp() async {
        PHPhotoLibrary.shared().unregisterChangeObserver(watcher)
        debounce?.cancel()

        guard enabled else {
            // Next time it's switched on starts from that moment.
            since = 0
            return
        }
        guard let service else { return }
        importer.configure(serverIdentity: service.apiURL.absoluteString)
        importer.refreshAuthorization()
        guard importer.isAuthorized else { return }

        if since == 0 { since = Date().timeIntervalSince1970 }
        watcher.onChange = { Task { @MainActor in schedule(after: 30) } }
        PHPhotoLibrary.shared().register(watcher)
        schedule(after: 5)
    }

    /// Waits a little so a burst of changes (an iCloud sync, a batch of imports)
    /// becomes one pass.
    private func schedule(after seconds: Double) {
        guard enabled, !paused, since > 0, let service else { return }
        debounce?.cancel()
        let start = Date(timeIntervalSince1970: since).addingTimeInterval(-6 * 3600)
        debounce = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            importer.startAutomatic(service: service, since: start)
        }
    }
}
