import Foundation

/// One row of a justified photo grid: same-height items whose widths (already
/// scaled from each asset's own aspect ratio) sum exactly to the row's container width.
struct JustifiedRow {
    let items: [(asset: AssetSummary, width: CGFloat)]
    let height: CGFloat
}

/// Packs assets into rows that fill the available width edge-to-edge while
/// preserving each photo's true aspect ratio, the way Google Photos/Immich's own
/// web client lay out a justified grid — as opposed to cropping everything to a square.
enum JustifiedLayout {
    static func rows(
        for assets: [AssetSummary],
        containerWidth: CGFloat,
        targetRowHeight: CGFloat,
        spacing: CGFloat
    ) -> [JustifiedRow] {
        guard containerWidth > 0, !assets.isEmpty else { return [] }

        // Works on index ranges so each photo is copied once, into its final row, however
        // many photos there are.
        func naturalWidth(_ index: Int) -> CGFloat {
            let ratio = assets[index].ratio
            return targetRowHeight * CGFloat(ratio > 0 ? ratio : 1)
        }

        func row(_ range: Range<Int>, naturalTotal: CGFloat) -> JustifiedRow {
            let totalSpacing = CGFloat(range.count - 1) * spacing
            guard naturalTotal > 0 else {
                return JustifiedRow(items: range.map { (assets[$0], naturalWidth($0)) }, height: targetRowHeight)
            }
            let scale = (containerWidth - totalSpacing) / naturalTotal
            return JustifiedRow(items: range.map { (assets[$0], naturalWidth($0) * scale) }, height: targetRowHeight * scale)
        }

        var rows: [JustifiedRow] = []
        rows.reserveCapacity(assets.count / 3 + 1)
        var start = 0
        var currentWidth: CGFloat = 0

        for index in assets.indices {
            let width = naturalWidth(index)
            let spacingSoFar = CGFloat(index - start) * spacing
            if index > start, currentWidth + width + spacingSoFar > containerWidth {
                rows.append(row(start..<index, naturalTotal: currentWidth))
                start = index
                currentWidth = width
            } else {
                currentWidth += width
            }
        }

        let last = start..<assets.count
        let totalSpacing = CGFloat(last.count - 1) * spacing
        // Only stretch the trailing row to fill the width if it's already close to full —
        // a half-empty last row (e.g. one leftover photo) looks better left at natural size.
        if currentWidth + totalSpacing >= containerWidth * 0.5 {
            rows.append(row(last, naturalTotal: currentWidth))
        } else {
            rows.append(JustifiedRow(items: last.map { (assets[$0], naturalWidth($0)) }, height: targetRowHeight))
        }
        return rows
    }
}
