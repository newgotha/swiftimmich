import AppKit
import SwiftUI
import XCTest
@testable import SwiftImmich

/// Draws the interface pieces to PNG files so their look can be checked by eye. Only runs when
/// `SNAPSHOT_DIR` names a folder; otherwise it is skipped.
@MainActor
final class VisualSnapshotTests: XCTestCase {
    private func snapshot<V: View>(_ name: String, size: CGSize, dark: Bool = false, @ViewBuilder _ content: () -> V) async throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"])
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content().frame(width: size.width, height: size.height).background(Palette.page))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func samplePhoto() -> NSImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 300, height: 220, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1), CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 300, y: 220), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.85)); context.fillEllipse(in: CGRect(x: 100, y: 60, width: 100, height: 100))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 300, height: 220))
    }

    private func buttons(hover: Bool) -> some View {
        HStack(spacing: 14) {
            Button { } label: { Label("Select", systemImage: "checkmark.circle") }.buttonStyle(ToolbarPillStyle())
            Button("Discard") { }.buttonStyle(HoverBorderedStyle())
            Button("Save Changes") { }.buttonStyle(HoverProminentStyle())
            Button("Disabled") { }.buttonStyle(HoverProminentStyle()).disabled(true)
            Button { } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(HoverPlainStyle())
            Button { } label: { Image(systemName: "heart") }.buttonStyle(HoverPlainStyle())
        }
        .environment(\.forcedHover, hover)
        .padding(20)
    }

    func testButtonsAtRestAndOnHover() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil)
        try await snapshot("buttons-rest", size: CGSize(width: 640, height: 70)) { buttons(hover: false) }
        try await snapshot("buttons-hover", size: CGSize(width: 640, height: 70)) { buttons(hover: true) }
        try await snapshot("buttons-hover-dark", size: CGSize(width: 640, height: 70), dark: true) { buttons(hover: true) }
    }

    func testSidebarRowsAtRestAndOnHover() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil)
        func sidebar(hover: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Label("Library", systemImage: "photo.on.rectangle").padding(.vertical, 4).sidebarHover(isSelected: true)
                Label("Favorites", systemImage: "heart").padding(.vertical, 4).sidebarHover()
                Label("Memories", systemImage: "sparkles").padding(.vertical, 4).sidebarHover()
            }
            .environment(\.forcedHover, hover)
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        try await snapshot("sidebar-rest", size: CGSize(width: 220, height: 120)) { sidebar(hover: false) }
        try await snapshot("sidebar-hover", size: CGSize(width: 220, height: 120)) { sidebar(hover: true) }
    }

    func testSelectedPhotosShrink() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil)
        await ThumbnailLoader.shared.seed(assetId: "snap-photo", image: samplePhoto())
        let request = URLRequest(url: URL(string: "https://immich.test/thumb")!)
        func cell(selected: Bool, badges: Bool = false) -> some View {
            var asset = AssetSummary(id: "snap-photo", isFavorite: badges, isImage: true, ratio: 1.36)
            asset.livePhotoVideoId = badges ? "v" : nil
            return AssetThumbnailView(asset: asset, request: request, size: CGSize(width: 204, height: 150), isSelected: selected)
        }
        try await snapshot("selection", size: CGSize(width: 680, height: 190)) {
            HStack(spacing: 12) { cell(selected: false); cell(selected: true); cell(selected: true, badges: true) }.padding(12)
        }
    }
}
