import CoreImage
import Foundation

/// One-tap styles for a photo, built from Core Image's own filters.
enum Look: String, CaseIterable, Identifiable, Equatable, Sendable {
    case none, vivid, dramatic, warm, cool, fade, chrome, instant, mono, silvertone, noir

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .dramatic: return "Dramatic"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .instant: return "Instant"
        case .mono: return "Mono"
        case .silvertone: return "Silvertone"
        case .noir: return "Noir"
        }
    }

    func render(_ image: CIImage) -> CIImage {
        switch self {
        case .none: return image
        case .vivid:
            return Self.controls(Self.filter("CIVibrance", image, [kCIInputAmountKey: 0.7]), saturation: 1.12, contrast: 1.06)
        case .dramatic:
            let shaded = Self.filter("CIHighlightShadowAdjust", image, ["inputHighlightAmount": 0.75, "inputShadowAmount": 0.25])
            return Self.controls(shaded, saturation: 0.82, contrast: 1.3)
        case .warm:
            return Self.temperature(image, target: 4700)
        case .cool:
            return Self.temperature(image, target: 8600)
        case .fade: return Self.filter("CIPhotoEffectFade", image)
        case .chrome: return Self.filter("CIPhotoEffectChrome", image)
        case .instant: return Self.filter("CIPhotoEffectInstant", image)
        case .mono: return Self.filter("CIPhotoEffectMono", image)
        case .silvertone: return Self.filter("CIPhotoEffectTonal", image)
        case .noir: return Self.filter("CIPhotoEffectNoir", image)
        }
    }

    private static func filter(_ name: String, _ image: CIImage, _ values: [String: Any] = [:]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in values { filter.setValue(value, forKey: key) }
        return filter.outputImage ?? image
    }

    private static func controls(_ image: CIImage, saturation: Double, contrast: Double) -> CIImage {
        filter("CIColorControls", image, [kCIInputSaturationKey: saturation, kCIInputContrastKey: contrast])
    }

    private static func temperature(_ image: CIImage, target: Double) -> CIImage {
        filter("CITemperatureAndTint", image, ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: target, y: 0)])
    }
}
