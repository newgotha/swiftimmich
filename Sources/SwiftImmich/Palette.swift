import AppKit
import SwiftUI

/// The app's own colours, each with a light and a dark version that switch with the
/// appearance. Anything not listed here uses the system's semantic colours.
enum Palette {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    // Page, toolbar and cards
    /// What the grid pages are drawn on (measured from the rendered window in light; the system colour in dark, which macOS tints). The header fade must match it exactly.
    static let pageNS = dynamic(light: rgb(244, 243, 245), dark: .windowBackgroundColor)
    static let toolbarNS = dynamic(light: .white, dark: rgb(38, 38, 40))
    static let cardNS = dynamic(light: .white, dark: rgb(44, 44, 46))
    static let cardBorderNS = dynamic(light: NSColor(white: 0.82, alpha: 1), dark: NSColor(white: 0.3, alpha: 1))
    static let panelNS = dynamic(light: NSColor(white: 0.96, alpha: 1), dark: NSColor(white: 0.19, alpha: 1))

    static let page = Color(nsColor: pageNS)
    static let toolbar = Color(nsColor: toolbarNS)
    static let card = Color(nsColor: cardNS)
    static let cardBorder = Color(nsColor: cardBorderNS)
    static let panel = Color(nsColor: panelNS)

    // Toolbar controls
    static let pillFillNS = dynamic(light: NSColor(white: 0.925, alpha: 1), dark: NSColor(white: 0.24, alpha: 1))
    static let pillPressedNS = dynamic(light: NSColor(white: 0.85, alpha: 1), dark: NSColor(white: 0.31, alpha: 1))
    static let pillHoverNS = dynamic(light: NSColor(white: 0.885, alpha: 1), dark: NSColor(white: 0.29, alpha: 1))
    static let pillSelectedNS = dynamic(light: NSColor(white: 0.79, alpha: 1), dark: NSColor(white: 0.38, alpha: 1))
    static let pillBorderNS = dynamic(light: NSColor(white: 0.74, alpha: 1), dark: NSColor(white: 0.4, alpha: 1))
    static let pillTextNS = dynamic(light: NSColor(white: 0.2, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
    static let pillPlaceholderNS = dynamic(light: NSColor(white: 0.42, alpha: 1), dark: NSColor(white: 0.62, alpha: 1))

    /// Resolves a dynamic colour for one appearance, for layers that only take fixed colours.
    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

/// Follow the Mac's light/dark setting, or force one.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearanceMode"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var saved: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
