import AppKit
import SwiftUI

/// The sliders and one-tap looks in the viewer's Edit panel.
struct EditControls: View {
    let adjustments: ImageAdjustments
    /// The picture the look thumbnails are drawn from.
    let baseImage: NSImage?
    /// True while a crop is applied; straightening starts the crop over.
    let cropIsPending: Bool
    let change: (@escaping (inout ImageAdjustments) -> Void) -> Void
    let changeStraighten: (Double) -> Void

    @State private var thumbnails: [Look: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            looks
            group("Light") {
                slider("Brightness", adjustments.brightness, -0.5...0.5, identity: 0) { value in change { $0.brightness = value } }
                slider("Contrast", adjustments.contrast, 0.5...1.5, identity: 1) { value in change { $0.contrast = value } }
                slider("Shadows", adjustments.shadows, 0...1, identity: 0) { value in change { $0.shadows = value } }
                slider("Highlights", adjustments.highlights, 0...1, identity: 0) { value in change { $0.highlights = value } }
            }
            group("Colour") {
                slider("Saturation", adjustments.saturation, 0...2, identity: 1) { value in change { $0.saturation = value } }
                slider("Warmth", adjustments.warmth, -1...1, identity: 0) { value in change { $0.warmth = value } }
            }
            group("Detail") {
                slider("Sharpen", adjustments.sharpness, 0...1, identity: 0) { value in change { $0.sharpness = value } }
                slider("Vignette", adjustments.vignette, 0...1, identity: 0) { value in change { $0.vignette = value } }
            }
            group("Straighten") {
                slider("Angle", adjustments.straighten, -15...15, identity: 0, format: { String(format: "%+.1f°", $0) }) { changeStraighten($0) }
                if cropIsPending {
                    Text("Straightening starts the crop over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: baseImage.map(ObjectIdentifier.init)) { await renderThumbnails() }
    }

    // MARK: - Looks

    private var looks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Look.allCases) { look in
                        Button { change { $0.look = look } } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2))
                                    if let thumbnail = thumbnails[look] {
                                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                                    }
                                }
                                .frame(width: 64, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(adjustments.look == look ? Color.accentColor : Color.clear, lineWidth: 2.5)
                                )
                                Text(look.title)
                                    .font(.caption2)
                                    .foregroundStyle(adjustments.look == look ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(HoverPlainStyle())
                        .accessibilityLabel("\(look.title) look")
                        .accessibilityAddTraits(adjustments.look == look ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            if adjustments.look != .none {
                slider("Look", adjustments.lookIntensity, 0...1, identity: 1) { value in change { $0.lookIntensity = value } }
            }
        }
    }

    private func renderThumbnails() async {
        guard let baseImage else { thumbnails = [:]; return }
        let rendered = await Task.detached(priority: .utility) { () -> [Look: NSImage] in
            guard let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [:] }
            var small = CIImage(cgImage: cgImage)
            let scale = 160 / max(small.extent.width, small.extent.height)
            small = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            var result: [Look: NSImage] = [:]
            for look in Look.allCases {
                var adjustments = ImageAdjustments()
                adjustments.look = look
                if let image = ImageRenderer.nsImage(from: adjustments.apply(to: small)) { result[look] = image }
            }
            return result
        }.value
        thumbnails = rendered
    }

    // MARK: - Rows

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(
        _ label: String,
        _ value: Double,
        _ range: ClosedRange<Double>,
        identity: Double,
        format: ((Double) -> String)? = nil,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .accessibilityLabel(label)
            Text(format?(value) ?? String(format: "%+.2f", value - identity))
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == identity ? .tertiary : .secondary)
                .frame(width: 46, alignment: .trailing)
            Button {
                onChange(identity)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(HoverPlainStyle())
            .foregroundStyle(.secondary)
            .opacity(value == identity ? 0 : 1)
            .help("Reset \(label)")
            .accessibilityLabel("Reset \(label)")
        }
    }
}
