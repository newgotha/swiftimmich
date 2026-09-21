import SwiftUI

/// The maths behind the date strip: each month gets a slice of the strip roughly in
/// proportion to how many photos it holds (with a minimum so quiet months stay reachable),
/// so dragging along it tracks how far down the scroll view you'd expect to be.
struct ScrubberModel: Equatable {
    struct Slice: Equatable {
        let key: String        // the time bucket, e.g. "2024-03-01T00:00:00.000Z"
        let year: String
        let start: Double      // 0...1 down the strip
        let end: Double
    }

    let slices: [Slice]

    /// `buckets` newest first, as the timeline returns them.
    init(buckets: [(key: String, count: Int)]) {
        let weights = buckets.map { max(Double($0.count), 8) }
        let total = weights.reduce(0, +)
        var cursor = 0.0
        var built: [Slice] = []
        for (bucket, weight) in zip(buckets, weights) {
            let span = total > 0 ? weight / total : 0
            built.append(Slice(key: bucket.key, year: String(bucket.key.prefix(4)), start: cursor, end: cursor + span))
            cursor += span
        }
        slices = built
    }

    /// The month under a position (0 = top of the strip, 1 = bottom).
    func slice(at fraction: Double) -> Slice? {
        guard !slices.isEmpty else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return slices.first { clamped < $0.end } ?? slices.last
    }

    /// Where each year begins, for the labels down the side.
    var yearMarks: [(year: String, position: Double)] {
        var seen = Set<String>()
        var marks: [(String, Double)] = []
        for slice in slices where seen.insert(slice.year).inserted {
            marks.append((slice.year, slice.start))
        }
        return marks
    }
}

/// A slim strip on the right edge: hover for the year marks, click or drag to jump.
struct TimelineScrubber: View {
    let model: ScrubberModel
    let title: (String) -> String
    let onJump: (String) -> Void

    @State private var dragFraction: Double?
    @State private var lastKey: String?
    @State private var voiceOverIndex = 0

    private let stripWidth: CGFloat = 38

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topTrailing) {
                ForEach(visibleMarks(height: height), id: \.year) { mark in
                    Text(mark.year)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: stripWidth, alignment: .trailing)
                        .offset(y: mark.position * height)
                }
                if let fraction = dragFraction, let slice = model.slice(at: fraction) {
                    Text(title(slice.key))
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
                        .fixedSize()
                        .offset(x: -stripWidth - 6, y: min(max(fraction * height - 12, 0), height - 26))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: stripWidth, height: height, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = height > 0 ? value.location.y / height : 0
                        dragFraction = fraction
                        if let slice = model.slice(at: fraction), slice.key != lastKey {
                            lastKey = slice.key
                            onJump(slice.key)
                        }
                    }
                    .onEnded { _ in
                        dragFraction = nil
                        lastKey = nil
                    }
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: stripWidth)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityHint("Drag to jump to a month, or swipe up and down to step through months")
        .accessibilityAdjustableAction { direction in
            let last = model.slices.count - 1
            guard last >= 0 else { return }
            switch direction {
            case .increment: voiceOverIndex = min(voiceOverIndex + 1, last)
            case .decrement: voiceOverIndex = max(voiceOverIndex - 1, 0)
            @unknown default: return
            }
            onJump(model.slices[voiceOverIndex].key)
        }
    }

    /// Year labels that would overlap are skipped so the strip stays legible.
    private func visibleMarks(height: CGFloat) -> [(year: String, position: Double)] {
        var result: [(String, Double)] = []
        var lastY = -Double.infinity
        for mark in model.yearMarks {
            let y = mark.position * Double(height)
            if y - lastY >= 16 {
                result.append(mark)
                lastY = y
            }
        }
        return result
    }
}
