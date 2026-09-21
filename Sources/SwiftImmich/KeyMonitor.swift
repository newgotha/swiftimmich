import AppKit
import AVKit
import SwiftUI

/// Sees every key press in the app's main window while it's on screen, and lets the
/// handler claim it by returning true.
///
/// A local event monitor rather than SwiftUI's `.onKeyPress`, which only fires while the
/// view holds keyboard focus — and nothing in a photo grid or viewer reliably does.
/// Presses are ignored while a text field is being edited, and when they're aimed at a
/// sheet, popover or dialog rather than the main window, so typing a name or
/// pressing Return in a dialog never triggers a photo shortcut.
struct KeyMonitor: NSViewRepresentable {
    var handler: (KeyPress) -> Bool

    struct KeyPress {
        let keyCode: UInt16
        /// Lower-cased character, ignoring modifiers ("" for non-character keys).
        let character: String
        let command: Bool
        let shift: Bool
        let option: Bool
        let control: Bool
        /// A list (the sidebar) has keyboard focus, so arrow keys belong to it.
        var inList = false

        var isPlain: Bool { !command && !option && !control }
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handler = handler
    }

    final class MonitorView: NSView {
        var handler: ((KeyPress) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.shouldHandle(event) else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let press = KeyPress(
                    keyCode: event.keyCode,
                    character: event.charactersIgnoringModifiers?.lowercased() ?? "",
                    command: flags.contains(.command),
                    shift: flags.contains(.shift),
                    option: flags.contains(.option),
                    control: flags.contains(.control),
                    inList: self.window?.firstResponder is NSTableView || self.window?.firstResponder is NSOutlineView
                )
                return self.handler?(press) == true ? nil : event
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window === NSApp.mainWindow, window.attachedSheet == nil else { return false }
            // Typing in the search box, a rename field, etc.
            if window.firstResponder is NSText { return false }
            return true
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

enum VideoKeys {
    /// Plays or pauses the video on screen, if there is one.
    @MainActor static func togglePlayback() -> Bool {
        guard let content = NSApp.mainWindow?.contentView, let view = playerView(in: content), let player = view.player else { return false }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        return true
    }

    private static func playerView(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        for subview in view.subviews {
            if let found = playerView(in: subview) { return found }
        }
        return nil
    }
}

/// Grid shortcuts: Space/Return opens the photo under the pointer, F favorites, Delete
/// trashes, Esc leaves selection mode. They act on the selection if there is one,
/// otherwise on the photo under the pointer. A modifier of its own because
/// ContentView's body is at the compiler's type-checking limit.
struct GridKeyCommands: ViewModifier {
    @ObservedObject var selection: GridSelection

    func body(content: Content) -> some View {
        content.background(KeyMonitor { press in handle(press) })
    }

    private var targets: [AssetSummary] {
        if selection.isSelecting && selection.count > 0 { return Array(selection.selected.values) }
        return selection.actionTarget.map { [$0.asset] } ?? []
    }

    private static func direction(for keyCode: UInt16) -> GridNavigator.Direction? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }

    private func handle(_ press: KeyMonitor.KeyPress) -> Bool {
        guard selection.openViewers == 0 else { return false }
        if var item = selection.quickLook, press.isPlain {
            switch press.keyCode {
            case 49, 53: selection.quickLook = nil
            case 123: item.index = max(item.index - 1, 0); selection.quickLook = item
            case 124: item.index = min(item.index + 1, item.assets.count - 1); selection.quickLook = item
            case 36:
                selection.quickLook = nil
                item.activate(item.current)
            default: return false
            }
            return true
        }
        let filter = selection.actionTarget?.filter ?? selection.lastFilter

        if !press.command && !press.option && !press.control, let direction = Self.direction(for: press.keyCode) {
            // The sidebar keeps the arrows unless you're pointing at photos or already moving around them.
            guard selection.focusedId != nil || selection.hovered != nil || !press.inList else { return false }
            return selection.moveFocus(direction, extend: press.shift)
        }
        if press.command && !press.option && !press.control && !press.shift && press.character == "a" {
            return selection.selectAllLoaded()
        }

        if press.isPlain && !press.shift {
            switch press.keyCode {
            case 53:
                if selection.isSelecting {
                    selection.end()
                    return true
                }
                guard selection.focusedId != nil else { return false }
                selection.focusedId = nil
                return true
            case 49:
                // Space previews the highlighted photo, or the one under the pointer, Finder-style.
                guard let hovered = selection.actionTarget, let index = hovered.neighbors.firstIndex(where: { $0.id == hovered.asset.id }) else { return false }
                selection.quickLook = QuickLookItem(assets: hovered.neighbors, index: index, activate: hovered.activate)
                return true
            case 36:
                guard let hovered = selection.actionTarget else { return false }
                hovered.open()
                return true
            case 51, 117:
                return requestDelete(filter: filter)
            default: break
            }
            if let stars = Int(press.character), (0...5).contains(stars), !filter.isTrashed, !targets.isEmpty {
                let assets = targets
                guard assets.allSatisfy({ selection.service?.isMine($0) ?? true }) else { return true }
                Task { await selection.setRating(assets, to: stars == 0 ? nil : stars) }
                return true
            }
            if press.character == "f", !filter.isTrashed, !targets.isEmpty {
                let assets = targets
                guard assets.allSatisfy({ selection.service?.isMine($0) ?? true }) else { return true }
                let makeFavorite = !assets.allSatisfy(\.isFavorite)
                Task { await selection.setFavorite(assets, to: makeFavorite) }
                return true
            }
        }
        if press.command && !press.option && !press.control && press.keyCode == 51 {
            return requestDelete(filter: filter)
        }
        return false
    }

    private func requestDelete(filter: TimelineFilter) -> Bool {
        let assets = targets
        guard !assets.isEmpty else { return false }
        guard assets.allSatisfy({ selection.service?.isMine($0) ?? true }) else { return true }
        if filter.isTrashed { selection.pendingPermanentDelete = assets } else { selection.pendingDelete = assets }
        return true
    }
}

/// File-drop uploading and the grid keyboard shortcuts, bundled into one modifier so
/// ContentView's body only pays for a single line.
struct WindowExtras: ViewModifier {
    let service: ImmichService?
    let center: TransferCenter
    let selection: GridSelection
    let importer: PhotosImporter
    let directory: PeopleDirectory
    let locked: LockedFolderSession

    func body(content: Content) -> some View {
        content
            .environmentObject(locked)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in locked.appDeactivated() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in locked.appActivated() }
            .modifier(AutoImport(service: service, importer: importer))
            .modifier(FileDropUpload(service: service, center: center))
            .modifier(GridKeyCommands(selection: selection))
            .modifier(AlbumSharingPresenter(service: service, selection: selection))
            .modifier(QuickLookPresenter(service: service, selection: selection))
            .modifier(ShareLinkPresenter(service: service, selection: selection))
            .modifier(TagDialogsAndToast(selection: selection))
            .modifier(FaceNamingPresenter(service: service, selection: selection, directory: directory))
            .modifier(ActivityPresenter(service: service, selection: selection))
    }
}
