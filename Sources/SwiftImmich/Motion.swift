import AppKit
import SwiftUI

/// Animations that stand down when the Mac's "Reduce motion" setting is on.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func animation(_ animation: Animation = .default) -> Animation? { reduced ? nil : animation }
}

@discardableResult
func withMotion<T>(_ animation: Animation = .default, _ body: () throws -> T) rethrows -> T {
    try withAnimation(Motion.animation(animation), body)
}
