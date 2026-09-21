import CoreGraphics
import Foundation

/// Everything needed to redo an edit from the original photo, stored on the edited copy's server
/// notes so the edit can be reopened and changed later. Versioned, and tolerant of missing or
/// unknown values, so a recipe written by another version still opens.
struct EditRecipe: Codable, Equatable {
    /// The note key it's stored under on the photo.
    static let key = "swiftimmich.edit.v1"

    struct CropBox: Codable, Equatable {
        var x: Double, y: Double, width: Double, height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        init(_ rect: CGRect) { (x, y, width, height) = (rect.minX, rect.minY, rect.width, rect.height) }
    }

    var version = 1
    /// The untouched original this edit was made from.
    var sourceId: String
    var rotation = 0
    var mirror = false
    var crop: CropBox?
    var adjustments = ImageAdjustments()

    init(sourceId: String, rotation: Int = 0, mirror: Bool = false, crop: CGRect? = nil, adjustments: ImageAdjustments = ImageAdjustments()) {
        self.sourceId = sourceId
        self.rotation = rotation
        self.mirror = mirror
        self.crop = crop.map(CropBox.init)
        self.adjustments = adjustments
    }

    init(_ recipe: ExportRecipe, sourceId: String) {
        self.init(sourceId: sourceId, rotation: recipe.rotation, mirror: recipe.mirror, crop: recipe.cropFraction, adjustments: recipe.adjustments)
    }

    var exportRecipe: ExportRecipe {
        ExportRecipe(rotation: rotation, mirror: mirror, cropFraction: crop?.rect, adjustments: adjustments, previewMean: nil)
    }

    /// True when nothing is changed, so there's nothing worth keeping.
    var isEmpty: Bool { rotation == 0 && !mirror && crop == nil && adjustments.isIdentity }

    private enum CodingKeys: String, CodingKey { case version, sourceId, rotation, mirror, crop, adjustments }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sourceId = try c.decode(String.self, forKey: .sourceId)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        crop = try c.decodeIfPresent(CropBox.self, forKey: .crop)
        adjustments = try c.decodeIfPresent(ImageAdjustments.self, forKey: .adjustments) ?? ImageAdjustments()
    }
}

extension Look: Codable {
    init(from decoder: Decoder) throws {
        // A look this version doesn't know is treated as none rather than losing the whole recipe.
        self = Look(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ImageAdjustments: Codable {
    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, autoEnhance, look, lookIntensity, warmth, shadows, highlights, sharpness, vignette, straighten
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        autoEnhance = try c.decodeIfPresent(AutoEnhance.self, forKey: .autoEnhance)
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? .none
        lookIntensity = try c.decodeIfPresent(Double.self, forKey: .lookIntensity) ?? 1
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encodeIfPresent(autoEnhance, forKey: .autoEnhance)
        try c.encode(look, forKey: .look)
        try c.encode(lookIntensity, forKey: .lookIntensity)
        try c.encode(warmth, forKey: .warmth)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(sharpness, forKey: .sharpness)
        try c.encode(vignette, forKey: .vignette)
        try c.encode(straighten, forKey: .straighten)
    }
}

extension ImmichService {
    /// What to tell someone whose "remove from stack" was refused. Immich won't take a stack's cover
    /// photo out of its stack, and its own message ("Cannot remove stack's primary asset") doesn't say what to do.
    static func removeFromStackMessage(for error: Error) -> String {
        if case ImmichServiceError.requestFailed(_, let message) = error, (message ?? "").lowercased().contains("primary asset") {
            return "This photo is the cover of its stack, and Immich won't take a stack's cover out of the stack. "
                + "Choose “Unstack All” to break the stack up instead."
        }
        return "Couldn't remove from the stack: \(AppLog.describe(error))"
    }

    /// Removes an edited copy and its stack membership, leaving the original as it was.
    ///
    /// Immich won't take a stack's cover out of its stack, so the stack is dissolved and, if other photos
    /// were in it (a burst, say), they're grouped again without the copy.
    func discardEditedCopy(copyId: String) async throws {
        if let stack = try await fetchAssetInfo(assetId: copyId).stack?.value1 {
            let remaining = try await fetchStack(id: stack.id).assets.map(\.id).filter { $0 != copyId }
            try await deleteStacks(ids: [stack.id])
            if remaining.count >= 2 { try await createStackInfo(assetIds: remaining) }
        }
        try await trashAsset(assetId: copyId)
    }

    /// Makes an edited copy the cover of a stack with its original, remembers how it was made, and
    /// tidies up the earlier copy when this replaces one. The original is never touched.
    ///
    /// If the original was already in a stack (a burst, say, or an earlier edit), the others stay in it.
    /// Returns the stack's id.
    @discardableResult
    func publishEditedCopy(newCopyId: String, originalId: String, replacing oldCopyId: String?, recipe: EditRecipe) async throws -> String {
        // Written first: if it fails, the copy is at worst a plain new photo, never a half-made stack.
        try await setAssetMetadata(recipe, key: EditRecipe.key, assetId: newCopyId)
        try await copyAssetMetadata(sourceId: originalId, targetId: newCopyId, copyStack: false)

        var members: [String] = []
        if let existing = try await fetchAssetInfo(assetId: originalId).stack?.value1 {
            members = try await fetchStack(id: existing.id).assets.map(\.id)
            try await deleteStacks(ids: [existing.id])
        }
        members.removeAll { $0 == newCopyId || $0 == oldCopyId }
        if !members.contains(originalId) { members.append(originalId) }

        // The first photo listed becomes the cover.
        let stack = try await createStackInfo(assetIds: [newCopyId] + members)
        if stack.primaryAssetId != newCopyId {
            try await setStackPrimary(stackId: stack.id, primaryAssetId: newCopyId)
        }
        if let oldCopyId { try await trashAsset(assetId: oldCopyId) }
        return stack.id
    }
}
