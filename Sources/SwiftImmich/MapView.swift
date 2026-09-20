import AppKit
import MapKit
import SwiftUI

/// A photo's position on the map.
final class PhotoAnnotation: NSObject, MKAnnotation {
    let assetId: String
    let coordinate: CLLocationCoordinate2D

    init(assetId: String, coordinate: CLLocationCoordinate2D) {
        self.assetId = assetId
        self.coordinate = coordinate
    }
}

/// A photo (or a cluster of nearby ones, with a count) drawn as a small framed thumbnail.
final class PhotoPinView: MKAnnotationView {
    static let reuseId = "photo-pin"
    static let clusterId = "photo-cluster"

    private let frameView = NSView()
    private let imageView = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private var loadedId: String?

    /// The framed thumbnail is 56 pt; the annotation view around it is larger, and centred
    /// on it, so the count badge can sit on the corner without being clipped by the view's
    /// own bounds.
    private static let thumbnailSize: CGFloat = 56
    private static let margin: CGFloat = 10

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let side = Self.thumbnailSize + Self.margin * 2
        frame = NSRect(x: 0, y: 0, width: side, height: side)

        frameView.frame = NSRect(x: Self.margin, y: Self.margin, width: Self.thumbnailSize, height: Self.thumbnailSize)
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = 8
        frameView.layer?.borderWidth = 3
        frameView.layer?.borderColor = NSColor.white.cgColor
        frameView.layer?.backgroundColor = NSColor.darkGray.cgColor
        frameView.layer?.shadowColor = NSColor.black.cgColor
        frameView.layer?.shadowOpacity = 0.45
        frameView.layer?.shadowRadius = 4
        frameView.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(frameView)

        imageView.frame = frameView.bounds.insetBy(dx: 3, dy: 3)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        frameView.addSubview(imageView)

        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.layer?.cornerRadius = 9
        badge.layer?.borderColor = NSColor.white.cgColor
        badge.layer?.borderWidth = 1.5
        badge.isHidden = true
        addSubview(badge)

        collisionMode = .rectangle
        clusteringIdentifier = "photo"
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Configures the view for its annotation — a single photo, or a cluster of them.
    func configure(service: ImmichService) {
        var cover: PhotoAnnotation?
        if let cluster = annotation as? MKClusterAnnotation {
            cover = cluster.memberAnnotations.first as? PhotoAnnotation
            let count = cluster.memberAnnotations.count
            badge.stringValue = count >= 1000 ? "\(count / 1000)k+" : "\(count)"
            let width = max(22, CGFloat(badge.stringValue.count) * 8 + 12)
            badge.frame = NSRect(x: bounds.maxX - width, y: bounds.maxY - 18, width: width, height: 18)
            badge.isHidden = false
        } else {
            cover = annotation as? PhotoAnnotation
            badge.isHidden = true
        }
        guard let id = cover?.assetId, id != loadedId else { return }
        loadedId = id
        imageView.image = nil
        // Videos are asked for without the "edited" flag, which would blank their thumbnail.
        let request = service.thumbnailRequest(assetId: id, isImage: false)
        Task { @MainActor [weak self] in
            let image = await ThumbnailLoader.shared.image(for: id, request: request)
            if self?.loadedId == id { self?.imageView.image = image }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadedId = nil
        imageView.image = nil
    }
}

/// MapKit's own map (not SwiftUI's `Map`), because it clusters tens of thousands of
/// pins on its own and stays smooth doing it.
struct PhotoMapView: NSViewRepresentable {
    let service: ImmichService
    let markers: [ImmichService.MapMarker]
    let markersVersion: Int
    let mapType: MKMapType
    var onOpenPhoto: (String) -> Void
    var onOpenArea: (Double, Double, Double, Double) -> Void
    var onVisibleChange: (Double, Double, Double, Double, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.reuseId)
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.clusterId)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        map.mapType = mapType
        guard context.coordinator.loadedVersion != markersVersion else { return }
        context.coordinator.loadedVersion = markersVersion
        context.coordinator.load(markers, into: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoMapView
        var loadedVersion = -1
        private var coordinates: [(lat: Double, lon: Double)] = []
        private var isFirstLoad = true

        init(_ parent: PhotoMapView) { self.parent = parent }

        func load(_ markers: [ImmichService.MapMarker], into map: MKMapView) {
            map.removeAnnotations(map.annotations)
            coordinates = markers.map { ($0.latitude, $0.longitude) }
            let annotations = markers.map {
                PhotoAnnotation(assetId: $0.id, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
            }
            map.addAnnotations(annotations)
            guard !annotations.isEmpty else { reportVisible(map); return }

            // Frame where the photos are, on the first load only (refreshing the
            // markers shouldn't yank the view away from where you're looking).
            if isFirstLoad {
                isFirstLoad = false
                var rect = MKMapRect.null
                for marker in markers {
                    let point = MKMapPoint(CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude))
                    rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
                }
                map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 60, left: 60, bottom: 90, right: 60), animated: false)
            }
            reportVisible(map)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let isCluster = annotation is MKClusterAnnotation
            guard isCluster || annotation is PhotoAnnotation else { return nil }
            let id = isCluster ? PhotoPinView.clusterId : PhotoPinView.reuseId
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation) as? PhotoPinView)
                ?? PhotoPinView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.configure(service: parent.service)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer {
                if let annotation = view.annotation { mapView.deselectAnnotation(annotation, animated: false) }
            }
            if let cluster = view.annotation as? MKClusterAnnotation {
                let members = cluster.memberAnnotations
                let lats = members.map(\.coordinate.latitude), lons = members.map(\.coordinate.longitude)
                let west = lons.min() ?? 0, east = lons.max() ?? 0, south = lats.min() ?? 0, north = lats.max() ?? 0
                // Photos taken in one spot can never be pulled apart by zooming, so
                // show them as a grid instead.
                if east - west < 0.0006 && north - south < 0.0006 {
                    let pad = 0.0004
                    parent.onOpenArea(west - pad, south - pad, east + pad, north + pad)
                } else {
                    mapView.showAnnotations(members, animated: true)
                }
            } else if let photo = view.annotation as? PhotoAnnotation {
                parent.onOpenPhoto(photo.assetId)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            reportVisible(mapView)
        }

        private func reportVisible(_ map: MKMapView) {
            let rect = map.visibleMapRect
            let topLeft = MKMapPoint(x: rect.minX, y: rect.minY).coordinate
            let bottomRight = MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate
            let north = topLeft.latitude, south = bottomRight.latitude
            let west = topLeft.longitude, east = bottomRight.longitude
            // A view wider than the world (or across the date line) can't be a simple box.
            let wraps = west > east
            let count = coordinates.reduce(0) { total, c in
                let insideLat = c.lat <= north && c.lat >= south
                let insideLon = wraps ? (c.lon >= west || c.lon <= east) : (c.lon >= west && c.lon <= east)
                return total + (insideLat && insideLon ? 1 : 0)
            }
            // Deferred: this can run while SwiftUI is still applying an update.
            let report = parent.onVisibleChange
            DispatchQueue.main.async { report(wraps ? -180 : west, south, wraps ? 180 : east, north, count) }
        }
    }
}

/// The "Map" page: your geotagged photos as thumbnails on a map.
struct MapPage: View {
    let service: ImmichService

    private struct AreaRequest: Hashable {
        let west: Double, south: Double, east: Double, north: Double
    }
    private struct PhotoRequest: Hashable {
        let assets: [AssetSummary]
    }

    @State private var markers: [ImmichService.MapMarker] = []
    @State private var version = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var favoritesOnly = false
    @State private var satellite = false
    @State private var visible = AreaRequest(west: -180, south: -85, east: 180, north: 85)
    @State private var visibleCount = 0
    @State private var area: AreaRequest?
    @State private var photo: PhotoRequest?

    var body: some View {
        ZStack(alignment: .bottom) {
            PhotoMapView(
                service: service,
                markers: markers,
                markersVersion: version,
                mapType: satellite ? .hybrid : .standard,
                onOpenPhoto: { id in openPhoto(id) },
                onOpenArea: { w, s, e, n in area = AreaRequest(west: w, south: s, east: e, north: n) },
                onVisibleChange: { w, s, e, n, count in
                    visible = AreaRequest(west: w, south: s, east: e, north: n)
                    visibleCount = count
                }
            )

            if isLoading {
                ProgressView("Loading your photo locations…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity)
            } else if markers.isEmpty {
                Text("None of your photos have a location yet.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity)
            }

            if !markers.isEmpty {
                Button {
                    area = visible
                } label: {
                    Label(
                        visibleCount == 0
                            ? "No photos in this view"
                            : "Show \(visibleCount.formatted()) \(visibleCount == 1 ? "Photo" : "Photos") in This View",
                        systemImage: "photo.on.rectangle"
                    )
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(visibleCount == 0)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $satellite) {
                    Text("Map").tag(false)
                    Text("Satellite").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $favoritesOnly) {
                    Label("Favorites only", systemImage: favoritesOnly ? "heart.fill" : "heart")
                }
                .toggleStyle(.button)
                .help("Show only favorites")
            }
        }
        .task(id: favoritesOnly) { await load() }
        .navigationDestination(item: $area) { request in
            PhotoGridView(
                service: service,
                filter: .area(west: request.west, south: request.south, east: request.east, north: request.north)
            )
        }
        .navigationDestination(item: $photo) { request in
            PhotoViewerView(assets: request.assets, initialIndex: 0, service: service)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            markers = try await service.fetchMapMarkers(favoritesOnly: favoritesOnly)
            version += 1
        } catch {
            if !Task.isCancelled { errorMessage = "Couldn't load the map: \(error.localizedDescription)" }
        }
    }

    private func openPhoto(_ id: String) {
        Task {
            if let summary = try? await service.fetchSummary(assetId: id) {
                photo = PhotoRequest(assets: [summary])
            }
        }
    }
}
