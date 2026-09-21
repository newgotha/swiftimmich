import SwiftUI

/// The month / year label above each group of photos. It's pinned to the top while its
/// photos scroll beneath it, so it sits on a fade — solid page colour behind the text,
/// dissolving to clear just below it — that keeps the words legible over any photo.
struct SectionHeader: View {
    let title: String

    /// The page colour behind the photo grids.
    static let pageColor = Palette.page

    /// How far below the header the fade reaches. Long and eased so it dissolves gradually,
    /// with a little extra space under the label so most of it lies in the gap above the
    /// first row rather than over the photos.
    private static let fadeHeight: CGFloat = 48

    /// How much of the header's own bottom padding the fade starts inside, so it begins right
    /// under the text instead of after a solid band.
    private static let fadeStartsAbove: CGFloat = 12

    /// Opacity at even steps down the fade, following a smooth S-curve (1 - smoothstep) so
    /// there's no visible edge where it starts or ends.
    private static let fadeCurve: [Double] = [1, 0.9, 0.65, 0.35, 0.1, 0]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
        // Drawn behind the header but taller than it, and wider so it reaches both edges.
        .background(alignment: .top) {
            GeometryReader { geometry in
                LinearGradient(
                    stops: gradientStops(headerHeight: geometry.size.height),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: geometry.size.width + 60, height: geometry.size.height + Self.fadeHeight)
                .offset(x: -30)
            }
            .allowsHitTesting(false)
        }
    }

    private func gradientStops(headerHeight: CGFloat) -> [Gradient.Stop] {
        let total = headerHeight + Self.fadeHeight
        let solidEnd = total > 0 ? Double(max(headerHeight - Self.fadeStartsAbove, 0) / total) : 0
        var stops: [Gradient.Stop] = [.init(color: Self.pageColor, location: 0)]
        let steps = Self.fadeCurve.count
        for (index, opacity) in Self.fadeCurve.enumerated() {
            let location = solidEnd + (1 - solidEnd) * Double(index) / Double(steps - 1)
            stops.append(.init(color: Self.pageColor.opacity(opacity), location: min(location, 1)))
        }
        return stops
    }
}
