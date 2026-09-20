import SwiftUI

/// A page whose content sits in a white, rounded, bordered card in the middle of the
/// section — used for the settings-style screens (Sharing, Import from Photos, the Locked
/// Folder gate) rather than photo grids. Scrolls if the card is taller than the window.
struct CardPage<Content: View>: View {
    var maxWidth: CGFloat = 600
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(32)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(white: 0.82), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
}
