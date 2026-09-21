import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import SwiftImmich

/// Measures what the editing pipeline really does to pixels, using small synthetic pictures.
final class EditingEngineTests: XCTestCase {
    private let size = CGSize(width: 240, height: 160)

    private func picture(width: Int = 240, height: Int = 160, _ draw: (CGContext, CGSize) -> Void) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context, CGSize(width: width, height: height))
        return CIImage(cgImage: context.makeImage()!)
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        picture { context, size in
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Average (r, g, b, a) over a region, in 0...255.
    private func mean(_ image: CIImage, in region: CGRect? = nil) -> (r: Double, g: Double, b: Double, a: Double) {
        let area = (region ?? image.extent).integral
        var pixels = [UInt8](repeating: 0, count: Int(area.width * area.height) * 4)
        ImageRenderer.context.render(image, toBitmap: &pixels, rowBytes: Int(area.width) * 4, bounds: area, format: .RGBA8, colorSpace: ImageRenderer.sRGB)
        var sum = [0.0, 0.0, 0.0, 0.0]
        for index in stride(from: 0, to: pixels.count, by: 4) { for c in 0..<4 { sum[c] += Double(pixels[index + c]) } }
        let count = Double(pixels.count / 4)
        return (sum[0] / count, sum[1] / count, sum[2] / count, sum[3] / count)
    }

    private func lightness(_ image: CIImage, in region: CGRect? = nil) -> Double {
        let m = mean(image, in: region)
        return (m.r + m.g + m.b) / 3
    }

    func testAnUntouchedPhotoIsUnchanged() {
        let image = solid(0.4, 0.5, 0.6)
        XCTAssertTrue(ImageAdjustments().isIdentity)
        let out = ImageAdjustments().apply(to: image)
        let (a, b) = (mean(image), mean(out))
        XCTAssertEqual(a.r, b.r, accuracy: 0.6); XCTAssertEqual(a.g, b.g, accuracy: 0.6); XCTAssertEqual(a.b, b.b, accuracy: 0.6)
    }

    func testWarmthShiftsTheColourTheRightWay() {
        let grey = solid(0.5, 0.5, 0.5)
        var warm = ImageAdjustments(); warm.warmth = 0.8
        var cool = ImageAdjustments(); cool.warmth = -0.8
        let (w, c) = (mean(warm.apply(to: grey)), mean(cool.apply(to: grey)))
        XCTAssertGreaterThan(w.r - w.b, 10, "warmer means more red than blue")
        XCTAssertLessThan(c.r - c.b, -10, "cooler means more blue than red")
    }

    func testWarmAndCoolLooksAgreeWithTheirNames() {
        let grey = solid(0.5, 0.5, 0.5)
        var warm = ImageAdjustments(); warm.look = .warm
        var cool = ImageAdjustments(); cool.look = .cool
        let (w, c) = (mean(warm.apply(to: grey)), mean(cool.apply(to: grey)))
        XCTAssertGreaterThan(w.r - w.b, 10)
        XCTAssertLessThan(c.r - c.b, -10)
    }

    func testBlackAndWhiteLooksRemoveColour() {
        let red = solid(0.8, 0.2, 0.2)
        for look in [Look.mono, .noir, .silvertone] {
            var adjustments = ImageAdjustments(); adjustments.look = look
            let m = mean(adjustments.apply(to: red))
            XCTAssertEqual(m.r, m.g, accuracy: 4, "\(look.title) has no colour")
            XCTAssertEqual(m.g, m.b, accuracy: 4, "\(look.title) has no colour")
        }
    }

    func testLookIntensityBlendsBetweenOriginalAndLook() {
        let red = solid(0.8, 0.2, 0.2)
        func saturation(_ intensity: Double) -> Double {
            var a = ImageAdjustments(); a.look = .mono; a.lookIntensity = intensity
            let m = mean(a.apply(to: red))
            return max(m.r, m.g, m.b) - min(m.r, m.g, m.b)
        }
        XCTAssertGreaterThan(saturation(0), saturation(0.5))
        XCTAssertGreaterThan(saturation(0.5), saturation(1))
        let untouched = mean(red)
        var zero = ImageAdjustments(); zero.look = .noir; zero.lookIntensity = 0
        XCTAssertEqual(mean(zero.apply(to: red)).r, untouched.r, accuracy: 1)
    }

    func testEveryLookChangesAColourfulPicture() {
        let colourful = picture { context, size in
            let colours: [CGColor] = [CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1), CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1), CGColor(red: 0.8, green: 0.7, blue: 0.3, alpha: 1)]
            for (i, colour) in colours.enumerated() {
                context.setFillColor(colour)
                context.fill(CGRect(x: CGFloat(i) * size.width / 4, y: 0, width: size.width / 4, height: size.height))
            }
        }
        let before = mean(colourful)
        for look in Look.allCases where look != .none {
            var adjustments = ImageAdjustments(); adjustments.look = look
            let after = mean(adjustments.apply(to: colourful))
            let change = abs(after.r - before.r) + abs(after.g - before.g) + abs(after.b - before.b)
            XCTAssertGreaterThan(change, 3, "\(look.title) should visibly change the picture")
        }
    }

    func testVignetteDarkensTheCornersMoreThanTheCentre() {
        let grey = solid(0.6, 0.6, 0.6)
        var adjustments = ImageAdjustments(); adjustments.vignette = 1
        let out = adjustments.apply(to: grey)
        let corner = lightness(out, in: CGRect(x: 0, y: 0, width: 30, height: 30))
        let centre = lightness(out, in: CGRect(x: 105, y: 65, width: 30, height: 30))
        XCTAssertLessThan(corner, centre - 20)
        XCTAssertEqual(centre, lightness(grey, in: CGRect(x: 105, y: 65, width: 30, height: 30)), accuracy: 6, "the middle is left alone")
    }

    func testSharpeningStrengthensAnEdge() {
        let edge = picture { context, size in
            context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            context.setFillColor(CGColor(gray: 0.7, alpha: 1)); context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        var adjustments = ImageAdjustments(); adjustments.sharpness = 1
        let out = adjustments.apply(to: edge)
        // Right at the edge, sharpening pushes the bright side brighter and the dark side darker.
        func step(_ image: CIImage) -> Double {
            lightness(image, in: CGRect(x: 120, y: 60, width: 2, height: 40)) - lightness(image, in: CGRect(x: 118, y: 60, width: 2, height: 40))
        }
        XCTAssertGreaterThan(step(out), step(edge) + 6)
    }

    func testShadowsAndHighlightsRecoverDetail() {
        let dark = solid(0.12, 0.12, 0.12)
        let bright = solid(0.9, 0.9, 0.9)
        var lift = ImageAdjustments(); lift.shadows = 1
        var recover = ImageAdjustments(); recover.highlights = 1
        XCTAssertGreaterThan(lightness(lift.apply(to: dark)), lightness(dark) + 4)
        XCTAssertLessThan(lightness(recover.apply(to: bright)), lightness(bright) - 4)
    }

    func testStraighteningKeepsTheSizeAndLeavesNoEmptyCorners() {
        let image = solid(0.2, 0.5, 0.8)
        for degrees in [-15.0, -6.0, 3.0, 12.0] {
            var adjustments = ImageAdjustments(); adjustments.straighten = degrees
            let out = adjustments.straightened(image)
            XCTAssertEqual(out.extent, image.extent, "same size, so a crop drawn over it still lines up")
            for corner in [CGRect(x: 0, y: 0, width: 2, height: 2), CGRect(x: 238, y: 0, width: 2, height: 2), CGRect(x: 0, y: 158, width: 2, height: 2), CGRect(x: 238, y: 158, width: 2, height: 2)] {
                XCTAssertGreaterThan(mean(out, in: corner).a, 254, "no transparent wedge at \(degrees)°")
            }
        }
        var none = ImageAdjustments(); none.straighten = 0
        XCTAssertEqual(none.straightened(image).extent, image.extent)
    }

    func testStraighteningTurnsATiltedHorizonLevel() {
        // A horizon that rises to the right by ~5.7° (1 in 10).
        let tilted = picture(width: 400, height: 300) { context, size in
            context.setFillColor(CGColor(gray: 0.2, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.move(to: CGPoint(x: 0, y: 0)); context.addLine(to: CGPoint(x: size.width, y: 0))
            context.addLine(to: CGPoint(x: size.width, y: 190)); context.addLine(to: CGPoint(x: 0, y: 150)); context.closePath()
            context.fillPath()
        }
        func horizonRise(_ image: CIImage) -> Double {
            func edgeHeight(x: CGFloat) -> Double {
                var top = 0.0
                for y in stride(from: 0, to: 300, by: 2) where lightness(image, in: CGRect(x: x, y: CGFloat(y), width: 2, height: 2)) > 100 { top = Double(y) }
                return top
            }
            return edgeHeight(x: 380) - edgeHeight(x: 20)
        }
        let before = horizonRise(tilted)
        var adjustments = ImageAdjustments(); adjustments.straighten = -atan(40.0 / 400.0) * 180 / .pi
        let after = horizonRise(adjustments.straightened(tilted))
        XCTAssertGreaterThan(abs(before), 30)
        XCTAssertLessThan(abs(after), abs(before) / 3, "the horizon is much closer to level (\(before) → \(after))")
    }

    func testThePreviewAndTheExportAgreeOnBrightness() throws {
        let source = picture(width: 1600, height: 1000) { context, size in
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(CGColor(red: 0.8, green: 0.7, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 400, y: 250, width: 800, height: 500))
        }
        var adjustments = ImageAdjustments()
        adjustments.look = .vivid; adjustments.warmth = 0.3; adjustments.shadows = 0.4; adjustments.vignette = 0.5; adjustments.brightness = 0.05
        let cg = ImageRenderer.context.createCGImage(source, from: source.extent)!
        let preview = try XCTUnwrap(ImageAdjustments.renderPreview(of: NSImage(cgImage: cg, size: .zero), adjustments: adjustments))
        let previewImage = CIImage(cgImage: try XCTUnwrap(preview.cgImage(forProposedRect: nil, context: nil, hints: nil)))

        let recipe = ExportRecipe(rotation: 0, mirror: false, cropFraction: nil, adjustments: adjustments, previewMean: nil)
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let jpeg = try XCTUnwrap(recipe.render(originalData: try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        let exported = try XCTUnwrap(CIImage(data: jpeg))

        let (p, e) = (mean(previewImage), mean(exported))
        XCTAssertEqual(p.r, e.r, accuracy: 6); XCTAssertEqual(p.g, e.g, accuracy: 6); XCTAssertEqual(p.b, e.b, accuracy: 6)
    }

    func testExportStraightensBeforeCroppingSoTheCropKeepsItsShape() throws {
        let source = picture(width: 800, height: 600) { context, size in
            context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        }
        let cg = ImageRenderer.context.createCGImage(source, from: source.extent)!
        var adjustments = ImageAdjustments(); adjustments.straighten = 7
        let recipe = ExportRecipe(rotation: 0, mirror: false, cropFraction: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), adjustments: adjustments, previewMean: nil)
        let jpeg = try XCTUnwrap(recipe.render(originalData: try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))))
        let out = try XCTUnwrap(CIImage(data: jpeg))
        XCTAssertEqual(out.extent.width, 400, accuracy: 2)
        XCTAssertEqual(out.extent.height, 300, accuracy: 2)
        XCTAssertGreaterThan(mean(out, in: CGRect(x: 0, y: 0, width: 4, height: 4)).a, 250)
    }

    func testTonalIdentityIgnoresStraightenButIdentityDoesNot() {
        var a = ImageAdjustments(); a.straighten = 4
        XCTAssertTrue(a.isTonalIdentity)
        XCTAssertFalse(a.isIdentity, "a straightened photo still needs to be saved as a new file")
        a.warmth = 0.1
        XCTAssertFalse(a.isTonalIdentity)
    }
}

final class CropGeometryTests: XCTestCase {
    func testPresetsGiveTheRightPixelShapeInEitherOrientation() {
        XCTAssertNil(CropAspect.free.pixelRatio(imageAspect: 1.5, portrait: false))
        XCTAssertEqual(CropAspect.original.pixelRatio(imageAspect: 1.25, portrait: false), 1.25)
        XCTAssertEqual(CropAspect.square.pixelRatio(imageAspect: 1.5, portrait: true), 1)
        XCTAssertEqual(CropAspect.fourThree.pixelRatio(imageAspect: 1.5, portrait: false) ?? 0, 4.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(CropAspect.fourThree.pixelRatio(imageAspect: 1.5, portrait: true) ?? 0, 3.0 / 4, accuracy: 0.0001)
        XCTAssertEqual(CropAspect.sixteenNine.pixelRatio(imageAspect: 1, portrait: false) ?? 0, 16.0 / 9, accuracy: 0.0001)
        XCTAssertFalse(CropAspect.square.canFlip)
        XCTAssertTrue(CropAspect.threeTwo.canFlip)
    }

    func testTheLargestRectangleOfAShapeFitsCentredInThePicture() {
        // A 3:2 picture cropped to a square: full height, two-thirds of the width.
        let square = CropGeometry.fit(fractionalRatio: CropGeometry.fractionalRatio(pixelRatio: 1, imageAspect: 1.5))
        XCTAssertEqual(square.height, 1, accuracy: 0.0001)
        XCTAssertEqual(square.width, 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(square.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(square.midY, 0.5, accuracy: 0.0001)
        // 16:9 out of a 4:3 picture: full width, less than full height.
        let wide = CropGeometry.fit(fractionalRatio: CropGeometry.fractionalRatio(pixelRatio: 16.0 / 9, imageAspect: 4.0 / 3))
        XCTAssertEqual(wide.width, 1, accuracy: 0.0001)
        XCTAssertLessThan(wide.height, 1)
        // In pixels the result really is 16:9.
        XCTAssertEqual((wide.width * 4.0 / 3) / wide.height, 16.0 / 9, accuracy: 0.001)
    }

    func testDraggingACornerKeepsTheShape() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let ratio: CGFloat = 1
        let dragged = CGRect(x: 0.2, y: 0.2, width: 0.55, height: 0.47)   // bottom-right pulled out unevenly
        let result = CropGeometry.constrained(dragged, moving: .bottomRight, start: start, fractionalRatio: ratio, minSize: 0.08)
        XCTAssertEqual(result.width / result.height, ratio, accuracy: 0.0001)
        XCTAssertEqual(result.minX, 0.2, accuracy: 0.0001, "the opposite corner stays put")
        XCTAssertEqual(result.minY, 0.2, accuracy: 0.0001)
    }

    func testEveryCornerAnchorsTheOppositeOne() {
        let start = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2)
        let ratio: CGFloat = 1.5
        let topLeft = CropGeometry.constrained(CGRect(x: 0.1, y: 0.15, width: 0.5, height: 0.35), moving: .topLeft, start: start, fractionalRatio: ratio, minSize: 0.08)
        XCTAssertEqual(topLeft.maxX, 0.6, accuracy: 0.0001); XCTAssertEqual(topLeft.maxY, 0.5, accuracy: 0.0001)
        let topRight = CropGeometry.constrained(CGRect(x: 0.3, y: 0.15, width: 0.5, height: 0.35), moving: .topRight, start: start, fractionalRatio: ratio, minSize: 0.08)
        XCTAssertEqual(topRight.minX, 0.3, accuracy: 0.0001); XCTAssertEqual(topRight.maxY, 0.5, accuracy: 0.0001)
        let bottomLeft = CropGeometry.constrained(CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.35), moving: .bottomLeft, start: start, fractionalRatio: ratio, minSize: 0.08)
        XCTAssertEqual(bottomLeft.maxX, 0.6, accuracy: 0.0001); XCTAssertEqual(bottomLeft.minY, 0.3, accuracy: 0.0001)
        for rect in [topLeft, topRight, bottomLeft] { XCTAssertEqual(rect.width / rect.height, ratio, accuracy: 0.0001) }
    }

    func testTheRectangleNeverLeavesThePictureOrShrinksAwayToNothing() {
        let start = CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)
        let huge = CropGeometry.constrained(CGRect(x: 0.5, y: 0.5, width: 3, height: 3), moving: .bottomRight, start: start, fractionalRatio: 1, minSize: 0.08)
        XCTAssertLessThanOrEqual(huge.maxX, 1.0001)
        XCTAssertLessThanOrEqual(huge.maxY, 1.0001)
        let tiny = CropGeometry.constrained(CGRect(x: 0.5, y: 0.5, width: 0, height: 0), moving: .bottomRight, start: start, fractionalRatio: 2, minSize: 0.08)
        XCTAssertGreaterThanOrEqual(tiny.width, 0.08)
        XCTAssertGreaterThanOrEqual(tiny.height, 0.04)
        XCTAssertEqual(tiny.width / tiny.height, 2, accuracy: 0.0001)
    }
}

/// The edit panel renders look thumbnails and a dozen sliders; it must settle rather than redraw forever.
@MainActor
final class EditPanelSettlesTests: XCTestCase {
    func testTheEditControlsRenderAndThenGoQuiet() async throws {
        _ = NSApplication.shared
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 600, height: 400))

        var changes = 0
        let controls = EditControls(
            adjustments: ImageAdjustments(), baseImage: image, cropIsPending: true,
            change: { mutate in var copy = ImageAdjustments(); mutate(&copy); changes += 1 },
            changeStraighten: { _ in changes += 1 }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: controls.frame(width: 420, height: 700)))
        window.setContentSize(NSSize(width: 420, height: 700))
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: .seconds(2))   // thumbnails render
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func cpu() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        }
        let before = cpu()
        try await Task.sleep(for: .seconds(2))
        let busy = (cpu() - before) / 2
        XCTAssertLessThan(busy, 0.4, "the panel keeps the main thread busy (\(Int(busy * 100))%) with nothing happening")
        XCTAssertEqual(changes, 0, "drawing the panel changes nothing by itself")
    }
}

/// How long one slider tick costs, printed so changes can be compared.
final class EditingSpeedTests: XCTestCase {
    private func bigPhoto() -> NSImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 3200, height: 2400, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 2400))
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 800, y: 600, width: 1600, height: 1200))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 3200, height: 2400))
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(body)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// A noisy JPEG-backed photo, like the ones the viewer keeps in memory.
    private func jpegPhoto(width: Int = 2000, height: Int = 1500) -> NSImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator), blue: .random(in: 0...1, using: &generator), alpha: 1))
            context.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &generator), y: .random(in: 0..<CGFloat(height), using: &generator), width: 120, height: 90))
        }
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
        return NSImage(data: data)!
    }

    func testTicksOnAJPEGBackedPhoto() {
        let photo = jpegPhoto()
        var adjustments = ImageAdjustments(); adjustments.straighten = 4
        _ = ImageAdjustments.renderStraightened(of: photo, degrees: 4)
        let straight = milliseconds { for _ in 0..<5 { _ = ImageAdjustments.renderStraightened(of: photo, degrees: 4) } } / 5
        let combined = milliseconds { for _ in 0..<5 { _ = ImageAdjustments.renderPreview(of: photo, adjustments: adjustments, includeStraighten: true) } } / 5
        let thumbs = milliseconds {
            var small = CIImage(cgImage: photo.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            let scale = 160 / max(small.extent.width, small.extent.height)
            small = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            for look in Look.allCases { var a = ImageAdjustments(); a.look = look; _ = ImageRenderer.nsImage(from: a.apply(to: small)) }
        }
        print("BENCH jpeg-backed 2000px: straighten base \(String(format: "%.1f", straight)) ms; combined preview \(String(format: "%.1f", combined)) ms; all 11 look thumbnails \(String(format: "%.1f", thumbs)) ms")
    }

    func testOneStraightenTickIsCheap() {
        let photo = bigPhoto()
        var adjustments = ImageAdjustments(); adjustments.straighten = 4; adjustments.look = .vivid; adjustments.vignette = 0.3
        _ = ImageAdjustments.renderPreview(of: photo, adjustments: adjustments, includeStraighten: true)   // warm up
        let tick = milliseconds { for _ in 0..<5 { _ = ImageAdjustments.renderPreview(of: photo, adjustments: adjustments, includeStraighten: true) } } / 5
        let base = milliseconds { for _ in 0..<5 { _ = ImageAdjustments.renderStraightened(of: photo, degrees: 4) } } / 5
        print("BENCH straighten tick (combined preview): \(String(format: "%.1f", tick)) ms; straightened base at full size: \(String(format: "%.1f", base)) ms")
        XCTAssertLessThan(tick, 120, "a slider tick should stay well inside a few frames")
    }
}
