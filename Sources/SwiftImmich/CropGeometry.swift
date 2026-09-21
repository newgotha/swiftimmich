import CoreGraphics
import Foundation

/// Fixed crop shapes to choose from.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, threeTwo, fourThree, sixteenNine, fiveFour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .threeTwo: return "3 : 2"
        case .fourThree: return "4 : 3"
        case .sixteenNine: return "16 : 9"
        case .fiveFour: return "5 : 4"
        }
    }

    /// Whether the shape has a landscape and a portrait version to flip between.
    var canFlip: Bool {
        switch self {
        case .free, .original, .square: return false
        default: return true
        }
    }

    /// Width divided by height in pixels, or nil for freeform. `imageAspect` is the picture's own width / height.
    func pixelRatio(imageAspect: CGFloat, portrait: Bool) -> CGFloat? {
        let landscape: CGFloat
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        case .threeTwo: landscape = 3.0 / 2
        case .fourThree: landscape = 4.0 / 3
        case .sixteenNine: landscape = 16.0 / 9
        case .fiveFour: landscape = 5.0 / 4
        }
        return portrait ? 1 / landscape : landscape
    }
}

enum CropGeometry {
    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// The crop rectangle is stored as fractions of the picture, so a shape that's 3:2 in pixels
    /// is a different ratio in those units whenever the picture itself isn't square.
    static func fractionalRatio(pixelRatio: CGFloat, imageAspect: CGFloat) -> CGFloat {
        pixelRatio / imageAspect
    }

    /// The largest rectangle of that fractional ratio that fits in the picture, centred.
    static func fit(fractionalRatio r: CGFloat) -> CGRect {
        let width: CGFloat = r >= 1 ? 1 : r
        let height: CGFloat = r >= 1 ? 1 / r : 1
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// Keeps a corner drag at a fixed shape: the opposite corner stays put, the size follows the
    /// pointer, and the result never leaves the picture.
    static func constrained(_ dragged: CGRect, moving corner: Corner, start: CGRect, fractionalRatio r: CGFloat, minSize: CGFloat) -> CGRect {
        let anchor = CGPoint(
            x: corner.isLeft ? start.maxX : start.minX,
            y: corner.isTop ? start.maxY : start.minY
        )
        let roomX = corner.isLeft ? anchor.x : 1 - anchor.x
        let roomY = corner.isTop ? anchor.y : 1 - anchor.y

        var width = max(dragged.width, dragged.height * r)
        width = max(width, minSize, minSize * r)
        width = min(width, roomX, roomY * r)
        let height = width / r
        return CGRect(
            x: corner.isLeft ? anchor.x - width : anchor.x,
            y: corner.isTop ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }
}
