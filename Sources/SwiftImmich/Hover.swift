import SwiftUI

private struct ForcedHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Draws every hover effect as if the pointer were over it — for previews and snapshot tests.
    var forcedHover: Bool {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

/// Hover, pressed and disabled looks for the app's buttons, so everything clickable reacts to the pointer.
enum HoverLook {
    static var animation: Animation? { Motion.animation(.easeOut(duration: 0.12)) }
}

/// A small icon or text button with no border of its own: a soft highlight appears behind it on hover.
struct HoverPlainStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    /// How far the highlight reaches beyond the button's own bounds.
    var inset: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        PlainBody(configuration: configuration, cornerRadius: cornerRadius, inset: inset)
    }

    private struct PlainBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let inset: CGFloat
        @State private var pointerInside = false
        @Environment(\.forcedHover) private var forced
        private var hovering: Bool { pointerInside || forced }
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering && isEnabled ? 0.09 : 0)))
                        .padding(-inset)
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { pointerInside = $0 }
                .animation(HoverLook.animation, value: hovering)
        }
    }
}

/// A tile or card (an album, a person, a memory): it lifts slightly on hover.
struct HoverCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var pointerInside = false
        @Environment(\.forcedHover) private var forced
        private var hovering: Bool { pointerInside || forced }

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : (hovering ? 1.035 : 1))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 6, y: 2)
                .contentShape(Rectangle())
                .onHover { pointerInside = $0 }
                .animation(HoverLook.animation, value: hovering)
        }
    }
}

private struct ButtonMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini: (horizontal, vertical) = (6, 2)
        case .small: (horizontal, vertical) = (9, 3)
        case .large: (horizontal, vertical) = (16, 7)
        case .extraLarge: (horizontal, vertical) = (18, 9)
        default: (horizontal, vertical) = (12, 5)
        }
    }
}

/// A button with a subtle fill and border that darkens on hover (the app's "bordered" button).
struct HoverBorderedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedBody(configuration: configuration)
    }

    private struct BorderedBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var pointerInside = false
        @Environment(\.forcedHover) private var forced
        private var hovering: Bool { pointerInside || forced }
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var size

        var body: some View {
            let metrics = ButtonMetrics(size)
            let fill = configuration.isPressed ? 0.20 : (hovering && isEnabled ? 0.13 : 0.07)
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
                .padding(.horizontal, metrics.horizontal)
                .padding(.vertical, metrics.vertical)
                .background(Color.primary.opacity(fill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(hovering && isEnabled ? 0.28 : 0.18), lineWidth: 0.75))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { pointerInside = $0 }
                .animation(HoverLook.animation, value: hovering)
        }
    }
}

/// The main action: filled with the accent colour, brighter on hover, darker while pressed.
struct HoverProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentBody(configuration: configuration)
    }

    private struct ProminentBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var pointerInside = false
        @Environment(\.forcedHover) private var forced
        private var hovering: Bool { pointerInside || forced }
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var size

        var body: some View {
            let metrics = ButtonMetrics(size)
            let base: Color = configuration.role == .destructive ? .red : .accentColor
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, metrics.horizontal)
                .padding(.vertical, metrics.vertical)
                .background(base, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .brightness(configuration.isPressed ? -0.14 : (hovering && isEnabled ? 0.14 : 0))
                .saturation(isEnabled ? 1 : 0.2)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { pointerInside = $0 }
                .animation(HoverLook.animation, value: hovering)
        }
    }
}

/// A soft highlight behind a sidebar row while the pointer is over it (the selected row keeps its own).
struct SidebarHover: ViewModifier {
    var isSelected = false
    @State private var pointerInside = false
    @Environment(\.forcedHover) private var forced
    private var hovering: Bool { pointerInside || forced }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && !isSelected ? 0.08 : 0))
                    .padding(.horizontal, -6)
                    .allowsHitTesting(false)
            }
            .onHover { pointerInside = $0 }
            .animation(HoverLook.animation, value: hovering)
    }
}

extension View {
    func sidebarHover(isSelected: Bool = false) -> some View { modifier(SidebarHover(isSelected: isSelected)) }
}
