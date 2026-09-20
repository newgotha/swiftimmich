import CoreImage
import XCTest
@testable import SwiftImmich

final class ImageTests: XCTestCase {
    private func solid(_ color: CIColor, width: CGFloat = 100, height: CGFloat = 60) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func testIdentityAdjustmentsChangeNothing() throws {
        let image = solid(CIColor(red: 0.4, green: 0.5, blue: 0.6))
        XCTAssertTrue(ImageAdjustments.identity.isIdentity)
        let result = ImageAdjustments.identity.apply(to: image)
        XCTAssertEqual(result.extent, image.extent)
        let before = try XCTUnwrap(ImageRenderer.meanRGB(image))
        let after = try XCTUnwrap(ImageRenderer.meanRGB(result))
        XCTAssertEqual(before, after, accuracy: 1)
    }

    func testBrightnessMakesTheImageLighter() throws {
        let image = solid(CIColor(red: 0.3, green: 0.3, blue: 0.3))
        var adjustments = ImageAdjustments()
        adjustments.brightness = 0.3
        XCTAssertFalse(adjustments.isIdentity)
        let before = try XCTUnwrap(ImageRenderer.meanRGB(image))
        let after = try XCTUnwrap(ImageRenderer.meanRGB(adjustments.apply(to: image)))
        XCTAssertGreaterThan(after, before + 20)
    }

    func testAutoEnhanceAtZeroIntensityIsANoOp() throws {
        let image = solid(CIColor(red: 0.2, green: 0.5, blue: 0.8))
        var adjustments = ImageAdjustments()
        adjustments.autoEnhance = .init(vibrance: 0.5, shadow: 0.5, intensity: 0)
        let before = try XCTUnwrap(ImageRenderer.meanRGB(image))
        let after = try XCTUnwrap(ImageRenderer.meanRGB(adjustments.apply(to: image)))
        XCTAssertEqual(before, after, accuracy: 1.5)
    }

    func testRotationAndMirrorMapToExifOrientations() {
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 0, mirror: false), .up)
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 90, mirror: false), .right)
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 180, mirror: false), .down)
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 270, mirror: false), .left)
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 0, mirror: true), .upMirrored)
        XCTAssertEqual(ImageRenderer.orientation(forRotation: 90, mirror: true), .leftMirrored)
    }

    func testExportRecipeRotatesAndCrops() throws {
        let source = try XCTUnwrap(ImageRenderer.jpegData(from: solid(CIColor(red: 0.5, green: 0.2, blue: 0.2), width: 200, height: 100)))

        let rotated = ExportRecipe(rotation: 90, mirror: false, cropFraction: nil, adjustments: .identity, previewMean: nil)
        let rotatedImage = try XCTUnwrap(ImageRenderer.loadOriginal(try XCTUnwrap(rotated.render(originalData: source))))
        XCTAssertEqual(rotatedImage.extent.width, 100, accuracy: 1)
        XCTAssertEqual(rotatedImage.extent.height, 200, accuracy: 1)

        let cropped = ExportRecipe(
            rotation: 0, mirror: false, cropFraction: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            adjustments: .identity, previewMean: nil
        )
        let croppedImage = try XCTUnwrap(ImageRenderer.loadOriginal(try XCTUnwrap(cropped.render(originalData: source))))
        XCTAssertEqual(croppedImage.extent.width, 100, accuracy: 1)
        XCTAssertEqual(croppedImage.extent.height, 50, accuracy: 1)
    }

    func testGarbageBytesFailCleanlyInsteadOfCrashing() {
        let recipe = ExportRecipe(rotation: 0, mirror: false, cropFraction: nil, adjustments: .identity, previewMean: nil)
        XCTAssertNil(recipe.render(originalData: Data([1, 2, 3, 4])))
    }
}
