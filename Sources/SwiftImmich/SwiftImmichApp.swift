import SwiftUI

@main
struct SwiftImmichApp: App {
    @StateObject private var importer = PhotosImporter()
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    init() {
        AppLog.installExceptionHook()
        // The interface is designed on light backgrounds (white toolbar, page-coloured grids,
        // white cards), so it always uses the light appearance rather than being half-dark.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            await UpdateChecker.shared.checkAtLaunchIfDue()
        }
        let info = Bundle.main.infoDictionary
        AppLog.info("launch \(info?["CFBundleShortVersionString"] as? String ?? "?") on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(photosImporter: importer)
                // Below this the toolbar (view switch, Select and search) no longer fits.
                .frame(minWidth: 980, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarStatus(importer: importer)
        } label: {
            MenuBarIcon(importer: importer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await UpdateChecker.shared.checkNow() } }
            }
            CommandGroup(after: .toolbar) {
                Button("Larger Thumbnails") { GridZoomStore.shared.adjust(by: 30) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Smaller Thumbnails") { GridZoomStore.shared.adjust(by: -30) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size Thumbnails") { GridZoomStore.shared.reset() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { ProblemReport.start() }
                Button("Show Error Log") {
                    if !FileManager.default.fileExists(atPath: AppLog.url.path) { AppLog.info("log opened") }
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.url])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Upload Files…") {
                    NotificationCenter.default.post(name: .requestUploadPanel, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}
