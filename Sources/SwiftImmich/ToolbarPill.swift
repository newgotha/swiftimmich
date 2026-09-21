import SwiftUI

/// One shared look for the toolbar's controls — the server button, Select, the
/// All Photos / Months / Years switch and the search box.
///
/// The system draws these as white shapes with a barely-there outline (measured: a
/// #F2F2F2 border on the toolbar's #FFFFFF, about 5% contrast) with pale grey text,
/// so on this app's white toolbar they nearly vanish. A visible fill, a real border and
/// darker text make them read clearly, and using the same values everywhere is what
/// keeps them looking like one family.
enum ToolbarPill {
    static let fill = Color(nsColor: Palette.pillFillNS)
    static let pressedFill = Color(nsColor: Palette.pillPressedNS)
    static let selectedFill = Color(nsColor: Palette.pillSelectedNS)
    static let border = Color(nsColor: Palette.pillBorderNS)
    static let text = Color(nsColor: Palette.pillTextNS)
    static let height: CGFloat = 31
    static let cornerRadius: CGFloat = 7
}

struct ToolbarPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ToolbarPill.text)
            .padding(.horizontal, 10)
            .frame(height: ToolbarPill.height)
            .toolbarPillBackground(fill: configuration.isPressed ? ToolbarPill.pressedFill : ToolbarPill.fill)
    }
}

extension View {
    func toolbarPillBackground(fill: Color = ToolbarPill.fill) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: ToolbarPill.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ToolbarPill.cornerRadius, style: .continuous)
                    .strokeBorder(ToolbarPill.border, lineWidth: 0.75)
            )
    }
}

/// The All Photos / Months / Years switch, drawn by hand so it can share the pill
/// styling (the system segmented control can't be recoloured).
struct GroupingControl: View {
    @Binding var selection: TimelineGrouping

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimelineGrouping.allCases) { grouping in
                Button {
                    selection = grouping
                } label: {
                    Text(grouping.rawValue)
                        .font(.callout.weight(selection == grouping ? .semibold : .regular))
                        .foregroundStyle(ToolbarPill.text)
                        // Every segment the same width (the widest label, "All Photos", fits
                        // in it), rather than each hugging its own text.
                        .frame(width: 86, height: ToolbarPill.height - 6)
                        .background(
                            selection == grouping ? ToolbarPill.selectedFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: ToolbarPill.cornerRadius - 2, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .toolbarPillBackground()
    }
}

/// Restyles the window's native search field to match `ToolbarPill`.
///
/// `.searchable` is used (rather than a hand-built field) because it's what pins the
/// search box to the far right of the toolbar and keeps the centred control centred —
/// custom toolbar items pack up next to the centred control instead. But SwiftUI gives
/// no way to recolour that field, so this reaches into AppKit: it finds the
/// `NSSearchField` and styles it, re-checking whenever the window updates because the
/// toolbar can rebuild the field (e.g. on resize).
struct SearchFieldStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView { StylerView() }
    func updateNSView(_ nsView: StylerView, context: Context) {}

    final class StylerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            restyle(in: window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.restyle(in: window)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private func restyle(in window: NSWindow) {
            guard let root = window.contentView?.superview else { return }
            for field in Self.searchFields(in: root) { Self.style(field) }
        }

        private static func searchFields(in view: NSView) -> [NSSearchField] {
            var found: [NSSearchField] = []
            if let field = view as? NSSearchField { found.append(field) }
            for subview in view.subviews { found += searchFields(in: subview) }
            return found
        }

        private static let pillBorderWidth: CGFloat = 0.75

        /// Once the native bezel is turned off, the cell draws its text flush with the
        /// top of the field instead of centred, so it's centred here. Applied by
        /// switching the existing cell's class in place, which is safe because the
        /// subclass adds no stored properties.
        private final class CenteredSearchFieldCell: NSSearchFieldCell {
            private func centred(_ rect: NSRect) -> NSRect {
                let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                guard rect.height > lineHeight else { return rect }
                var result = rect
                result.origin.y += (rect.height - lineHeight) / 2
                result.size.height = lineHeight
                return result
            }

            override func searchTextRect(forBounds rect: NSRect) -> NSRect { centred(super.searchTextRect(forBounds: rect)) }
            override func drawingRect(forBounds rect: NSRect) -> NSRect { centred(super.drawingRect(forBounds: rect)) }

            // With the bezel off, AppKit sizes the typing editor to the whole field, so
            // the caret and text land at the top-left behind the magnifier. Hand it the
            // same centred text rect the placeholder is drawn in.
            override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
                super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
            }

            override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
                super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
            }
        }

        private static func style(_ field: NSSearchField) {
            // The border width doubles as the "already styled" marker, so this is
            // cheap to call on every window update and only touches a field once.
            field.wantsLayer = true
            if let cell = field.cell, !(cell is CenteredSearchFieldCell) {
                object_setClass(cell, CenteredSearchFieldCell.self)
            }
            // Layer colours are fixed values, so they're redone when light/dark changes.
            let appearanceName = field.effectiveAppearance.name.rawValue
            guard field.layer?.borderWidth != pillBorderWidth || field.layer?.name != appearanceName else { return }
            field.layer?.name = appearanceName

            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.textColor = Palette.pillTextNS
            field.placeholderAttributedString = NSAttributedString(
                string: "Search your photos",
                attributes: [
                    .foregroundColor: Palette.pillPlaceholderNS,
                    .font: field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                ]
            )
            field.layer?.backgroundColor = Palette.resolved(Palette.pillFillNS, for: field.effectiveAppearance)
            field.layer?.borderColor = Palette.resolved(Palette.pillBorderNS, for: field.effectiveAppearance)
            field.layer?.borderWidth = pillBorderWidth
            field.layer?.cornerRadius = 7
        }
    }
}
