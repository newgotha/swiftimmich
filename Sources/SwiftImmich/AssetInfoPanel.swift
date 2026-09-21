import ImmichAPI
import SwiftUI
import UniformTypeIdentifiers

/// The photo's metadata, in a panel that slides up from the bottom of the viewer
/// (the same treatment as the edit panel).
struct AssetInfoPanel: View {
    /// The panel's fixed height, which the viewer also uses to shrink the photo so the
    /// panel doesn't cover it.
    static let height: CGFloat = 250

    let service: ImmichService
    let assetId: String
    /// False for someone else's photo, which can't be edited.
    var canEdit = true
    var onClose: () -> Void

    @State private var info: Components.Schemas.AssetResponseDto?
    @State private var albumNames: [String] = []
    @State private var faces: [Face] = []
    @State private var editingFaceId: String?
    @State private var showEditor = false
    @State private var errorMessage: String?
    @EnvironmentObject private var membership: AlbumMembership
    @EnvironmentObject private var directory: PeopleDirectory
    @EnvironmentObject private var selection: GridSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Info")
                    .font(.headline)
                Spacer()
                Button {
                    showEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.callout)
                }
                .buttonStyle(HoverPlainStyle())
                .foregroundStyle(Color.accentColor)
                .disabled(info == nil)
                .opacity(canEdit ? 1 : 0)
                .allowsHitTesting(canEdit)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close info")
                }
                .buttonStyle(HoverPlainStyle())
            }

            if let info {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(Self.rows(for: info, albumNames: albumNames), id: \.label) { row in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.value)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if info.exifInfo?.latitude != nil, info.exifInfo?.longitude != nil {
                        Button {
                            if let asset = thisAsset.first { Task { await selection.showOnMap(asset) } }
                        } label: {
                            Label("Show on Map", systemImage: "map")
                        }
                        .buttonStyle(ToolbarPillStyle())
                        .padding(.top, 10)
                    }
                    if canEdit {
                        ratingAndTags(info)
                            .padding(.top, 14)
                    }
                    if !faces.isEmpty {
                        peopleSection
                            .padding(.top, 14)
                    }
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                Spacer()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .sheet(isPresented: $showEditor) {
            MetadataEditor(service: service, assets: [AssetSummary(id: assetId, isFavorite: false, isImage: true, ratio: 1)]) {
                showEditor = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .assetMetadataChanged)) { note in
            guard (note.object as? [String])?.contains(assetId) == true else { return }
            let id = assetId
            Task {
                faces = (try? await service.fetchFaces(assetId: id)) ?? faces
                if let fresh = try? await service.fetchAssetInfo(assetId: id), id == assetId { info = fresh }
            }
        }
        // Reloads when the user pages to another photo while the panel is still open.
        .task(id: assetId) {
            info = nil
            albumNames = []
            faces = []
            errorMessage = nil
            do {
                info = try await service.fetchAssetInfo(assetId: assetId)
            } catch {
                if !Task.isCancelled { errorMessage = "Couldn't load info: \(error.localizedDescription)" }
            }
        }
        .task(id: assetId) {
            await directory.loadIfNeeded(service: service)
            faces = (try? await service.fetchFaces(assetId: assetId)) ?? []
        }
        // Asked of the server rather than read from the badge map, so it's right even
        // before that map has finished loading; re-asked whenever the app changes this
        // photo's albums (e.g. adding it to one from the toolbar with this pane open).
        .task(id: "\(assetId)|\(membership.albums(for: assetId).map(\.id))") {
            if let albums = try? await service.fetchAlbums(containing: assetId) {
                albumNames = albums.map(\.albumName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
        }
    }

    // MARK: - Rating and tags

    private var thisAsset: [AssetSummary] { [AssetSummary(id: assetId, isFavorite: false, isImage: true, ratio: 1)] }

    private func ratingAndTags(_ info: Components.Schemas.AssetResponseDto) -> some View {
        let rating = info.exifInfo?.rating ?? 0
        let assigned = info.tags ?? []
        let available = selection.tags.filter { tag in !assigned.contains { $0.id == tag.id } }
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            // Tapping the current rating again clears it.
                            Task { await selection.setRating(thisAsset, to: star == rating ? nil : star) }
                        } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                                .accessibilityAddTraits(star <= rating ? .isSelected : [])
                        }
                        .buttonStyle(HoverPlainStyle())
                    }
                    if rating < 0 {
                        Text("Rejected").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(assigned, id: \.id) { tag in
                        HStack(spacing: 4) {
                            Text(tag.value).font(.caption)
                            Button {
                                Task { await selection.untag(thisAsset, from: (id: tag.id, name: tag.value), removeFromGrid: false) }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .accessibilityLabel("Remove tag \(tag.value)")
                            }
                            .buttonStyle(HoverPlainStyle())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    Menu {
                        ForEach(available, id: \.id) { tag in
                            Button(tag.value) { Task { await selection.tag(thisAsset, with: tag) } }
                        }
                        if !available.isEmpty { Divider() }
                        Button("New Tag…") { selection.pendingNewTag = thisAsset }
                    } label: {
                        Label("Add", systemImage: "plus").font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - People

    /// One chip per face Immich found in the photo; tapping one lets you name it.
    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("People")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(faces, id: \.id) { face in
                    faceChip(face)
                }
            }
        }
    }

    private func faceChip(_ face: Face) -> some View {
        let name = face.matchedPerson?.name ?? ""
        return Button {
            editingFaceId = face.id
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let person = face.matchedPerson {
                        CoverImageView(
                            cacheKey: "person-\(person.id)",
                            request: service.personThumbnailRequest(personId: person.id)
                        )
                    } else {
                        Image(systemName: "person.crop.circle.dashed")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                Text(name.isEmpty ? "Add name" : name)
                    .font(.caption)
                    .foregroundStyle(name.isEmpty ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlainStyle())
        .popover(
            isPresented: Binding(
                get: { editingFaceId == face.id },
                set: { if !$0 { editingFaceId = nil } }
            ),
            arrowEdge: .top
        ) {
            PersonNameEditor(
                service: service,
                target: .face(face),
                onChanged: {
                    Task { faces = (try? await service.fetchFaces(assetId: assetId)) ?? faces }
                },
                onClose: { editingFaceId = nil }
            )
        }
    }

    // MARK: - Formatting

    private struct Row {
        let label: String
        let value: String
    }

    private static func rows(for info: Components.Schemas.AssetResponseDto, albumNames: [String]) -> [Row] {
        var rows: [Row] = []
        let exif = info.exifInfo

        // Immich stores this as the photographer's local clock time, not an instant,
        // so it's shown as-is (in UTC) rather than converted to this Mac's time zone.
        var taken = dateFormatter.string(from: info.localDateTime)
        if let zone = exif?.timeZone, !zone.isEmpty { taken += " (\(zone))" }
        rows.append(Row(label: "Taken", value: taken))

        rows.append(Row(label: "File name", value: info.originalFileName))

        if let mime = info.originalMimeType {
            rows.append(Row(label: "Type", value: UTType(mimeType: mime)?.localizedDescription ?? mime))
        }

        let width = info.width ?? exif?.exifImageWidth
        let height = info.height ?? exif?.exifImageHeight
        if let width, let height, width > 0, height > 0 {
            let megapixels = Double(width * height) / 1_000_000
            let size = megapixels >= 0.1 ? String(format: "%d × %d  ·  %.1f MP", width, height, megapixels) : "\(width) × \(height)"
            rows.append(Row(label: "Dimensions", value: size))
        }

        if let bytes = exif?.fileSizeInByte {
            rows.append(Row(label: "File size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }

        if let duration = info.duration, duration > 0 {
            rows.append(Row(label: "Duration", value: durationString(milliseconds: duration)))
        }

        if let camera = cameraName(make: exif?.make, model: exif?.model) {
            rows.append(Row(label: "Camera", value: camera))
        }
        if let lens = exif?.lensModel, !lens.isEmpty {
            rows.append(Row(label: "Lens", value: lens))
        }

        var exposure: [String] = []
        if let aperture = exif?.fNumber { exposure.append("ƒ/\(trimmed(aperture))") }
        if let time = exif?.exposureTime, !time.isEmpty { exposure.append("\(time) s") }
        if let iso = exif?.iso { exposure.append("ISO \(iso)") }
        if let focal = exif?.focalLength { exposure.append("\(trimmed(focal)) mm") }
        if !exposure.isEmpty {
            rows.append(Row(label: "Exposure", value: exposure.joined(separator: "  ·  ")))
        }

        let place = [exif?.city, exif?.state, exif?.country].compactMap { $0 }.filter { !$0.isEmpty }
        if !place.isEmpty {
            rows.append(Row(label: "Location", value: place.joined(separator: ", ")))
        }
        if let latitude = exif?.latitude, let longitude = exif?.longitude {
            rows.append(Row(label: "Coordinates", value: String(format: "%.5f°, %.5f°", latitude, longitude)))
        }

        if !albumNames.isEmpty {
            rows.append(Row(label: albumNames.count == 1 ? "Album" : "Albums", value: albumNames.joined(separator: ", ")))
        }

        if let description = exif?.description, !description.isEmpty {
            rows.append(Row(label: "Description", value: description))
        }

        return rows
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Phones often list the make and repeat it in the model ("Apple", "iPhone 15 Pro").
    private static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.localizedCaseInsensitiveContains(make) { return model }
        return "\(make) \(model)"
    }

    /// 1.8 rather than 1.80000001, and 24 rather than 24.0.
    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func durationString(milliseconds: Int) -> String {
        let total = Int((Double(milliseconds) / 1000).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
