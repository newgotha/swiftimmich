import SwiftUI

/// What one on-screen grid tells the keyboard navigator: its photos, and where each sits.
struct GridLayoutEntry {
    struct Cell: Equatable {
        let id: String
        let centerX: Double
    }

    /// Sections are ordered top to bottom by this (a month's position in the timeline).
    let order: Int
    let assets: [AssetSummary]
    let rows: [[Cell]]
    let filter: TimelineFilter
    let activate: (AssetSummary) -> Void
}

/// Moves a highlight around the photos with the arrow keys, across every grid on the page.
enum GridNavigator {
    enum Direction { case left, right, up, down }

    /// The photo the highlight moves to, or nil if it can't move. With nothing highlighted
    /// yet, any direction starts at the first photo.
    static func move(from id: String?, _ direction: Direction, rows: [[GridLayoutEntry.Cell]]) -> String? {
        let rows = rows.filter { !$0.isEmpty }
        guard let first = rows.first?.first else { return nil }
        guard let id, let (r, c) = position(of: id, in: rows) else { return first.id }

        switch direction {
        case .left:
            if c > 0 { return rows[r][c - 1].id }
            return r > 0 ? rows[r - 1].last?.id : nil
        case .right:
            if c + 1 < rows[r].count { return rows[r][c + 1].id }
            return r + 1 < rows.count ? rows[r + 1].first?.id : nil
        case .up:
            return r > 0 ? nearest(to: rows[r][c].centerX, in: rows[r - 1]) : nil
        case .down:
            return r + 1 < rows.count ? nearest(to: rows[r][c].centerX, in: rows[r + 1]) : nil
        }
    }

    private static func position(of id: String, in rows: [[GridLayoutEntry.Cell]]) -> (Int, Int)? {
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(where: { $0.id == id }) { return (r, c) }
        }
        return nil
    }

    private static func nearest(to x: Double, in row: [GridLayoutEntry.Cell]) -> String? {
        row.min { abs($0.centerX - x) < abs($1.centerX - x) }?.id
    }

    /// Cell centres for a laid-out grid, for registering with the navigator.
    static func cells(for rows: [JustifiedRow], spacing: CGFloat) -> [[GridLayoutEntry.Cell]] {
        rows.map { row in
            var x = 0.0
            return row.items.map { item in
                defer { x += Double(item.width + spacing) }
                return GridLayoutEntry.Cell(id: item.asset.id, centerX: x + Double(item.width) / 2)
            }
        }
    }
}

extension GridSelection {
    func register(_ token: UUID, _ entry: GridLayoutEntry) { layouts[token] = entry }
    func unregister(_ token: UUID) { layouts[token] = nil }

    private var orderedLayouts: [GridLayoutEntry] { layouts.values.sorted { $0.order < $1.order } }

    /// The photo the keyboard highlight is on, in the shape shortcuts act on.
    var focusedItem: Hovered? {
        guard let focusedId else { return nil }
        for entry in orderedLayouts {
            if let asset = entry.assets.first(where: { $0.id == focusedId }) {
                return Hovered(asset: asset, filter: entry.filter, neighbors: entry.assets, activate: entry.activate) {
                    entry.activate(asset)
                }
            }
        }
        return nil
    }

    /// What a bare key press acts on: the highlighted photo, otherwise the one under the pointer.
    var actionTarget: Hovered? { focusedItem ?? hovered }

    /// Moves the highlight; with `extend`, also selects the photos it passes over.
    /// False when there's no grid on screen to move around.
    func moveFocus(_ direction: GridNavigator.Direction, extend: Bool) -> Bool {
        let entries = orderedLayouts
        guard !entries.isEmpty else { return false }
        let start = focusedId ?? hovered?.asset.id
        guard let next = GridNavigator.move(from: start, direction, rows: entries.flatMap(\.rows)) else { return true }

        if extend {
            select([start, next].compactMap { $0 }.compactMap(asset(withId:)))
        }
        focusSetAt = Date()
        focusedId = next
        return true
    }

    /// Selects every photo currently loaded on the page.
    func selectAllLoaded() -> Bool {
        let assets = orderedLayouts.flatMap(\.assets)
        guard !assets.isEmpty else { return false }
        select(assets)
        return true
    }

    private func asset(withId id: String) -> AssetSummary? {
        for entry in layouts.values {
            if let found = entry.assets.first(where: { $0.id == id }) { return found }
        }
        return nil
    }
}
