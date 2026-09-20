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

        var rows: [JustifiedRow] = []
        var currentItems: [(AssetSummary, CGFloat)] = []
        var currentWidth: CGFloat = 0

        func naturalWidth(for asset: AssetSummary) -> CGFloat {
            let ratio = asset.ratio > 0 ? asset.ratio : 1
            return targetRowHeight * CGFloat(ratio)
        }

        for asset in assets {
            let width = naturalWidth(for: asset)
            let spacingSoFar = CGFloat(currentItems.count) * spacing

            if !currentItems.isEmpty, currentWidth + width + spacingSoFar > containerWidth {
                rows.append(finalizeRow(currentItems, containerWidth: containerWidth, spacing: spacing, targetHeight: targetRowHeight))
                currentItems = [(asset, width)]
                currentWidth = width
            } else {
                currentItems.append((asset, width))
                currentWidth += width
            }
        }

        if !currentItems.isEmpty {
            let totalSpacing = CGFloat(currentItems.count - 1) * spacing
            let naturalTotal = currentItems.reduce(0) { $0 + $1.1 } + totalSpacing
            // Only stretch the trailing row to fill the width if it's already close to full —
            // a half-empty last row (e.g. one leftover photo) looks better left at natural size.
            if naturalTotal >= containerWidth * 0.5 {
                rows.append(finalizeRow(currentItems, containerWidth: containerWidth, spacing: spacing, targetHeight: targetRowHeight))
            } else {
                rows.append(JustifiedRow(items: currentItems.map { ($0.0, $0.1) }, height: targetRowHeight))
            }
        }

        return rows
    }

    private static func finalizeRow(
        _ items: [(AssetSummary, CGFloat)],
        containerWidth: CGFloat,
        spacing: CGFloat,
        targetHeight: CGFloat
    ) -> JustifiedRow {
        let totalSpacing = CGFloat(items.count - 1) * spacing
        let naturalTotalWidth = items.reduce(0) { $0 + $1.1 }
        guard naturalTotalWidth > 0 else {
            return JustifiedRow(items: items.map { ($0.0, $0.1) }, height: targetHeight)
        }
        let scale = (containerWidth - totalSpacing) / naturalTotalWidth
        let scaledHeight = targetHeight * scale
        return JustifiedRow(items: items.map { ($0.0, $0.1 * scale) }, height: scaledHeight)
    }
}
