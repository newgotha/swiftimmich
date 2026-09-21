import AppKit
import SwiftUI

/// Coordinates the swipe-down "photo slides away while the grid fades in" transition.
///
/// It exists because the two halves can't overlap through navigation alone: while a
/// photo is open, the grid it came from isn't on screen, so the photo can't fade
/// "into" it. Instead the viewer pops back to the grid immediately, and a stand-in
/// copy of the photo (the ghost) carries on sliding and fading out on top of it, while
/// the grid itself starts fading in once the ghost is about half gone.
@MainActor
final class ViewerTransition: ObservableObject {
    struct Ghost: Identifiable {
        let id = UUID()
        let image: NSImage
        /// Window-space centre of where the photo was, and the size it was drawn at
        /// before rotation — exactly what the viewer had on screen.
        let center: CGPoint
        let size: CGSize
        let rotation: Int
        let mirror: Bool
    }

    static let ghostDuration = 0.3
    static let gridFadeDuration = 0.3

    @Published private(set) var ghost: Ghost?
    @Published private(set) var gridOpacity: Double = 1

    private var generation = 0

    func beginDismiss(ghost: Ghost?) {
        generation += 1
        let current = generation

        // No animation on this step: the viewer's removal and the ghost taking its
        // place have to look like nothing happened.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            self.ghost = ghost
            self.gridOpacity = 0
        }

        Task {
            // The grid starts fading in when the ghost is about halfway out.
            try? await Task.sleep(for: .seconds(Self.ghostDuration / 2))
            guard generation == current else { return }
            withMotion(.easeOut(duration: Self.gridFadeDuration)) { gridOpacity = 1 }

            try? await Task.sleep(for: .seconds(Self.ghostDuration / 2 + 0.05))
            guard generation == current else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { self.ghost = nil }
        }
    }
}

/// Draws the departing photo above the whole window while the grid fades in below it.
struct ViewerGhostOverlay: View {
    @ObservedObject var transition: ViewerTransition

    var body: some View {
        GeometryReader { proxy in
            if let ghost = transition.ghost {
                let origin = proxy.frame(in: .global).origin
                GhostImage(ghost: ghost)
                    .position(x: ghost.center.x - origin.x, y: ghost.center.y - origin.y)
                    .id(ghost.id)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GhostImage: View {
    let ghost: ViewerTransition.Ghost

    // Animated from its own onAppear, not driven from outside: a view inserted with
    // its final value already set never animates towards it.
    @State private var progress: CGFloat = 0

    var body: some View {
        Image(nsImage: ghost.image)
            .resizable()
            .frame(width: ghost.size.width, height: ghost.size.height)
            .rotationEffect(.degrees(Double(ghost.rotation)))
            .scaleEffect(x: ghost.mirror ? -1 : 1, y: 1)
            .offset(y: progress * 260)
            .opacity(1 - progress)
            .onAppear {
                // Ease in-out so "halfway out" is reached at half the time, which is
                // when the grid's fade-in begins.
                withMotion(.easeInOut(duration: ViewerTransition.ghostDuration)) { progress = 1 }
            }
    }
}
