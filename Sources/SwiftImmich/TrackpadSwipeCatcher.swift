import AppKit
import SwiftUI

/// Recognizes a two-finger trackpad swipe (no click required) and reports it as
/// left/right/up/down, for prev/next photo, closing the viewer, and showing photo
/// info. SwiftUI has no built-in gesture for this — a two-finger swipe arrives as a
/// precise-delta scroll-wheel event, which only NSView's `scrollWheel(with:)` can
/// see, so this drops into AppKit for it.
struct TrackpadSwipeCatcher: NSViewRepresentable {
    var onSwipeLeft: () -> Void
    var onSwipeRight: () -> Void
    var onSwipeUp: () -> Void = {}
    var onSwipeDown: () -> Void = {}

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: CatcherView) {
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
    }

    final class CatcherView: NSView {
        var onSwipeLeft: (() -> Void)?
        var onSwipeRight: (() -> Void)?
        var onSwipeUp: (() -> Void)?
        var onSwipeDown: (() -> Void)?

        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0
        private var hasTriggered = false
        private let triggerThreshold: CGFloat = 80
        /// How much larger the winning axis must be than the other before it counts,
        /// so a mostly-horizontal swipe that drifts a little vertically doesn't
        /// accidentally close the viewer (or the reverse).
        private let dominanceRatio: CGFloat = 1.6

        override func scrollWheel(with event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }
            if event.phase == .began {
                accumulatedX = 0
                accumulatedY = 0
                hasTriggered = false
            }
            // With "natural" scrolling on, the deltas already follow the fingers
            // (fingers left/up = negative); with it off they're reversed. Normalising
            // here means a swipe up always means fingers up, whatever the setting.
            let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            accumulatedX += event.scrollingDeltaX * direction
            accumulatedY += event.scrollingDeltaY * direction

            guard !hasTriggered else { return }
            let absX = abs(accumulatedX)
            let absY = abs(accumulatedY)

            if absX > triggerThreshold, absX > absY * dominanceRatio {
                hasTriggered = true
                if accumulatedX < 0 { onSwipeLeft?() } else { onSwipeRight?() }
            } else if absY > triggerThreshold, absY > absX * dominanceRatio {
                hasTriggered = true
                if accumulatedY < 0 { onSwipeUp?() } else { onSwipeDown?() }
            }
        }
    }
}
