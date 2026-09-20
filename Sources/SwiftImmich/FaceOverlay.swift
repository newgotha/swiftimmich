import ImmichAPI
import SwiftUI

/// Boxes drawn over the faces Immich found in the photo being viewed, each labelled with
/// the person's name (or "Add name"). Click one to name it.
///
/// The boxes are measured against the photo as it was analysed, so they're only drawn
/// when what's on screen is that same picture: not for a photo edited in Immich
/// (cropped, rotated, mirrored) and not while there's an unsaved edit in the viewer,
/// where they'd land on the wrong spots.
struct FaceOverlayView: View {
    let service: ImmichService
    let assetId: String
    /// The size the photo is drawn at.
    let size: CGSize

    @EnvironmentObject private var directory: PeopleDirectory
    @State private var faces: [Face] = []
    @State private var isUnedited = false
    @State private var hoveredFaceId: String?
    @EnvironmentObject private var selection: GridSelection

    private var usable: Bool {
        guard isUnedited, let first = faces.first, first.imageWidth > 0, first.imageHeight > 0, size.height > 0 else { return false }
        // A photo of a different shape isn't the picture the boxes were measured on.
        let analysed = Double(first.imageWidth) / Double(first.imageHeight)
        return abs(analysed - Double(size.width / size.height)) / analysed < 0.03
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if usable {
                ForEach(faces, id: \.id) { face in
                    box(for: face)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: assetId) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .assetMetadataChanged)) { note in
            if (note.object as? [String])?.contains(assetId) == true { Task { await load() } }
        }
    }

    @ViewBuilder
    private func box(for face: Face) -> some View {
        let scaleX = size.width / CGFloat(face.imageWidth)
        let scaleY = size.height / CGFloat(face.imageHeight)
        let width = CGFloat(face.boundingBoxX2 - face.boundingBoxX1) * scaleX
        let height = CGFloat(face.boundingBoxY2 - face.boundingBoxY1) * scaleY
        let name = face.matchedPerson?.name ?? ""

        // A real button rather than a tap gesture: it reliably claims the click.
        Button {
            AppLog.info("face box clicked (asset \(assetId), face \(face.id))")
            selection.pendingNameFace = PendingFace(face: face, assetId: assetId)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hoveredFaceId == face.id ? Color.accentColor : Color.white, lineWidth: hoveredFaceId == face.id ? 3 : 2)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                Text(name.isEmpty ? "Add name" : name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(name.isEmpty ? Color.white : Color.black)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(name.isEmpty ? Color.accentColor : Color.white, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .fixedSize()
                    .offset(y: 26)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height)
        .onHover { inside in
            if inside { hoveredFaceId = face.id } else if hoveredFaceId == face.id { hoveredFaceId = nil }
        }
        .help(name.isEmpty ? "Click to name this person" : "Click to change this name")
        .position(
            x: CGFloat(face.boundingBoxX1) * scaleX + width / 2,
            y: CGFloat(face.boundingBoxY1) * scaleY + height / 2
        )
    }

    private func load() async {
        let id = assetId
        async let fetchedFaces = service.fetchFaces(assetId: id)
        async let info = service.fetchAssetInfo(assetId: id)
        let loadedFaces = (try? await fetchedFaces) ?? []
        let unedited = (try? await info)?.isEdited == false
        guard id == assetId else { return }
        faces = loadedFaces
        isUnedited = unedited
        await directory.loadIfNeeded(service: service)
    }
}
