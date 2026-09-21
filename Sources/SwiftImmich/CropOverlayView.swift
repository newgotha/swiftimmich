import SwiftUI

/// A draggable, resizable crop rectangle drawn over an image. `cropRect` is stored
/// as FRACTIONAL coordinates (0...1 on each axis, relative to the image's bounds)
/// rather than absolute points — that makes it automatically stay correct no matter
/// how the image's on-screen size changes afterward (e.g. shrinking to make room for
/// a bottom bar), with no extra code needed to keep the two in sync. An earlier,
/// absolute-point version froze the rect's size/position at whatever the image's
/// dimensions happened to be the instant crop mode was entered, so a subsequent
/// resize left the handles visually detached from the image's actual edges.
struct CropOverlayView: View {
    let imageSize: CGSize
    @Binding var cropRect: CGRect
    /// When set, corner drags keep this width / height ratio (in the rectangle's own fractional units).
    var lockedRatio: CGFloat? = nil

    @State private var dragStartRect: CGRect?

    private let handleDiameter: CGFloat = 16
    private let minFractionalSize: CGFloat = 0.08

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var geometry: CropGeometry.Corner {
            switch self {
            case .topLeft: return .topLeft
            case .topRight: return .topRight
            case .bottomLeft: return .bottomLeft
            case .bottomRight: return .bottomRight
            }
        }
    }

    private var absoluteRect: CGRect {
        CGRect(
            x: cropRect.minX * imageSize.width,
            y: cropRect.minY * imageSize.height,
            width: cropRect.width * imageSize.width,
            height: cropRect.height * imageSize.height
        )
    }

    var body: some View {
        let rect = absoluteRect
        ZStack(alignment: .topLeading) {
            maskPath(rect)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: handleDiameter, height: handleDiameter)
                    .shadow(radius: 1)
                    .position(handlePosition(for: corner, in: rect))
                    .gesture(resizeGesture(for: corner))
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
    }

    private func maskPath(_ rect: CGRect) -> Path {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: imageSize))
            path.addRect(rect)
        }
    }

    private func handlePosition(for corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let start = dragStartRect ?? cropRect
                if dragStartRect == nil { dragStartRect = cropRect }
                let dx = value.translation.width / imageSize.width
                let dy = value.translation.height / imageSize.height
                var origin = CGPoint(x: start.origin.x + dx, y: start.origin.y + dy)
                origin.x = min(max(0, origin.x), 1 - start.width)
                origin.y = min(max(0, origin.y), 1 - start.height)
                cropRect = CGRect(origin: origin, size: start.size)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let start = dragStartRect ?? cropRect
                if dragStartRect == nil { dragStartRect = cropRect }
                let dx = value.translation.width / imageSize.width
                let dy = value.translation.height / imageSize.height
                var resized = resizedRect(from: start, corner: corner, dx: dx, dy: dy)
                if let lockedRatio {
                    resized = CropGeometry.constrained(resized, moving: corner.geometry, start: start, fractionalRatio: lockedRatio, minSize: minFractionalSize)
                }
                cropRect = resized
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func resizedRect(from start: CGRect, corner: Corner, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch corner {
        case .topLeft:
            let x = min(max(0, start.origin.x + dx), start.maxX - minFractionalSize)
            let y = min(max(0, start.origin.y + dy), start.maxY - minFractionalSize)
            return CGRect(x: x, y: y, width: start.maxX - x, height: start.maxY - y)
        case .topRight:
            let y = min(max(0, start.origin.y + dy), start.maxY - minFractionalSize)
            let width = min(max(minFractionalSize, start.width + dx), 1 - start.origin.x)
            return CGRect(x: start.origin.x, y: y, width: width, height: start.maxY - y)
        case .bottomLeft:
            let x = min(max(0, start.origin.x + dx), start.maxX - minFractionalSize)
            let height = min(max(minFractionalSize, start.height + dy), 1 - start.origin.y)
            return CGRect(x: x, y: start.origin.y, width: start.maxX - x, height: height)
        case .bottomRight:
            let width = min(max(minFractionalSize, start.width + dx), 1 - start.origin.x)
            let height = min(max(minFractionalSize, start.height + dy), 1 - start.origin.y)
            return CGRect(x: start.origin.x, y: start.origin.y, width: width, height: height)
        }
    }
}
