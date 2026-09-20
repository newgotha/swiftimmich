import AppKit
import CoreImage
import Foundation

/// Color adjustments that Immich's edit API can't store (it only supports
/// crop/rotate/mirror — see `ImmichService.EditAction`), so saving any non-identity
/// value always produces a real exported file.
///
/// The live preview and the final export both go through `apply(to:)`, on purpose:
/// the preview used to use SwiftUI's own `.brightness()/.contrast()/.saturation()`
/// modifiers while the export used Core Image, and the two don't agree, so a saved
/// photo never quite matched what the sliders had shown.
struct ImageAdjustments: Equatable {
    /// The amounts Core Image's own scene analysis suggested for one specific photo,
    /// captured once when Auto Enhance is tapped so the intensity slider can rescale
    /// them without re-running the analysis on every drag tick.
    struct AutoEnhance: Equatable {
        var vibrance: Double
        var shadow: Double
        var intensity: Double = 1
    }

    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var autoEnhance: AutoEnhance?

    static let identity = ImageAdjustments()

    var isIdentity: Bool { self == .identity }

    func apply(to image: CIImage) -> CIImage {
        var result = image

        if let auto = autoEnhance {
            // Core Image's suggested amounts are real but quite conservative — an
            // offline test showed applying them raw shifted a sample image by only
            // ~1-3/255 — so they're boosted (clamped to each filter's valid range)
            // and scaled by `intensity`. At intensity 0 everything below lands back
            // on its identity value, so 0 is a true no-op.
            if let filter = CIFilter(name: "CIVibrance") {
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(min(auto.vibrance * 2.5 * auto.intensity, 1), forKey: kCIInputAmountKey)
                if let output = filter.outputImage { result = output }
            }
            if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(min(auto.shadow * 2.5 * auto.intensity, 1), forKey: "inputShadowAmount")
                if let output = filter.outputImage { result = output }
            }
            // A small fixed contrast/saturation "pop" so Auto Enhance always does
            // something noticeable, regardless of how much this photo's analysis
            // happened to suggest.
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(result, forKey: kCIInputImageKey)
                filter.setValue(1 + 0.08 * auto.intensity, forKey: kCIInputContrastKey)
                filter.setValue(1 + 0.15 * auto.intensity, forKey: kCIInputSaturationKey)
                if let output = filter.outputImage { result = output }
            }
        }

        if brightness != 0 || contrast != 1 || saturation != 1, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(brightness, forKey: kCIInputBrightnessKey)
            filter.setValue(contrast, forKey: kCIInputContrastKey)
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
            if let output = filter.outputImage { result = output }
        }

        return result
    }

    /// Runs Core Image's scene analysis once and keeps only the two amounts this app
    /// actually uses (vibrance and shadow recovery).
    static func analyzeAutoEnhance(_ image: NSImage) -> AutoEnhance? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var vibrance = 0.0
        var shadow = 0.0
        for filter in CIImage(cgImage: cgImage).autoAdjustmentFilters() {
            if filter.name == "CIVibrance", let amount = filter.value(forKey: kCIInputAmountKey) as? NSNumber {
                vibrance = amount.doubleValue
            }
            if filter.name == "CIHighlightShadowAdjust", let amount = filter.value(forKey: "inputShadowAmount") as? NSNumber {
                shadow = amount.doubleValue
            }
        }
        return AutoEnhance(vibrance: vibrance, shadow: shadow)
    }

    /// A live-preview render: capped to a size comfortably above what the viewer
    /// actually shows on screen, since this runs on every slider tick and re-uploads
    /// the whole image to the display each time.
    static func renderPreview(of base: NSImage, adjustments: ImageAdjustments) -> NSImage? {
        guard let cgImage = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ciImage = CIImage(cgImage: cgImage)
        let longest = max(ciImage.extent.width, ciImage.extent.height)
        let maxDimension: CGFloat = 1200
        if longest > maxDimension {
            let scale = maxDimension / longest
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ImageRenderer.nsImage(from: adjustments.apply(to: ciImage))
    }
}

/// Everything needed to bake a saved edit into a real file, captured at the moment
/// the user clicks Save. Reading live view state instead — after the multi-second
/// download of the original — meant anything touched during the save (a slider,
/// a rotate) silently changed what got exported.
struct ExportRecipe: Sendable {
    var rotation: Int
    var mirror: Bool
    var cropFraction: CGRect?
    var adjustments: ImageAdjustments
    /// Brightness of the preview image the user was looking at, for diagnostics.
    var previewMean: Double?

    /// Order matters and matches the on-screen preview: orientation, then crop (its
    /// fractions were drawn against the already-oriented image), then adjustments.
    func render(originalData: Data) -> Data? {
        guard var image = ImageRenderer.loadOriginal(originalData) else { return nil }
        let decodedMean = ImageRenderer.meanRGB(image)

        if rotation != 0 || mirror {
            image = image.oriented(ImageRenderer.orientation(forRotation: rotation, mirror: mirror))
        }

        if let frac = cropFraction {
            let extent = image.extent
            let cropRect = CGRect(
                x: extent.minX + frac.minX * extent.width,
                y: extent.minY + (1 - frac.maxY) * extent.height,
                width: frac.width * extent.width,
                height: frac.height * extent.height
            ).integral
            image = image.cropped(to: cropRect)
        }

        image = adjustments.apply(to: image)

        let exportedMean = ImageRenderer.meanRGB(image)
        Diagnostics.log(
            "export: \(Int(image.extent.width))x\(Int(image.extent.height)) colorspace=\(image.colorSpace?.name as String? ?? "nil") "
            + "decodedOriginalMean=\(decodedMean.map { String(format: "%.1f", $0) } ?? "?") "
            + "previewBaseMean=\(previewMean.map { String(format: "%.1f", $0) } ?? "?") "
            + "exportedMean=\(exportedMean.map { String(format: "%.1f", $0) } ?? "?") "
            + "adjustments=\(adjustments)"
        )
        return ImageRenderer.jpegData(from: image)
    }
}

/// One shared context and one explicit output color space for every Core Image
/// render in the app — creating a `CIContext` per render is expensive, and leaving
/// the output color space implicit is how previews and exports can quietly diverge.
enum ImageRenderer {
    static let context = CIContext()
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func nsImage(from ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent.integral
        guard let cgImage = context.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: sRGB) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func jpegData(from ciImage: CIImage, quality: Double = 0.92) -> Data? {
        context.jpegRepresentation(
            of: ciImage,
            colorSpace: sRGB,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }

    /// Loads a downloaded original for baking. Goes through Core Image directly
    /// (rather than NSImage -> CGImage) so EXIF orientation is applied and HDR
    /// originals are tone-mapped down to SDR instead of being read as if they were
    /// already SDR, which renders them far darker and more contrasty than intended.
    static func loadOriginal(_ data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true, .toneMapHDRtoSDR: true])
    }

    /// `rotation` is always clockwise-as-displayed, matching `.rotationEffect`.
    /// `CGImagePropertyOrientation` encodes the same rotate-then-mirror combinations
    /// EXIF does, so this is a direct lookup rather than composed transforms —
    /// rotation and mirroring don't commute for the 90°/270° cases.
    static func orientation(forRotation rotation: Int, mirror: Bool) -> CGImagePropertyOrientation {
        switch (rotation, mirror) {
        case (0, false): return .up
        case (90, false): return .right
        case (180, false): return .down
        case (270, false): return .left
        case (0, true): return .upMirrored
        case (90, true): return .leftMirrored
        case (180, true): return .downMirrored
        case (270, true): return .rightMirrored
        default: return .up
        }
    }

    /// Average of the RGB channels, 0-255 — for diagnostics only.
    static func meanRGB(_ ciImage: CIImage) -> Double? {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: sRGB)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
    }
}

/// Appends a line to ~/Library/Logs/SwiftImmich-diagnostics.log. Used to find out
/// *why* an exported photo's brightness differs from its preview, since that can't
/// be worked out from outside the running app.
enum Diagnostics {
    static func log(_ message: String, to file: String = "SwiftImmich-diagnostics.log") {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(file)")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
