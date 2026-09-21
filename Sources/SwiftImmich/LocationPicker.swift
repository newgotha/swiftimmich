import MapKit
import SwiftUI

/// A point on the map, as plain numbers so it can be compared and stored in state.
struct PinLocation: Equatable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var text: String { String(format: "%.4f°, %.4f°", latitude, longitude) }
}

/// A small map for choosing where a photo was taken: click to drop the pin, or drag it.
struct LocationPickerMap: NSViewRepresentable {
    @Binding var pin: PinLocation?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)
        context.coordinator.map = map
        let start = pin.map { MKCoordinateRegion(center: $0.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)) }
            ?? MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 20, longitude: 10), span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 160))
        map.setRegion(start, animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(pin, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: LocationPickerMap
        weak var map: MKMapView?
        private let annotation = MKPointAnnotation()
        /// The last position this map itself reported, so it isn't recentred on its own edits.
        private var reported: PinLocation?

        init(_ parent: LocationPickerMap) { self.parent = parent }

        func show(_ pin: PinLocation?, on map: MKMapView) {
            guard let pin else {
                map.removeAnnotation(annotation)
                reported = nil
                return
            }
            if !map.annotations.contains(where: { $0 === annotation }) { map.addAnnotation(annotation) }
            guard pin != reported else { return }
            reported = pin
            annotation.coordinate = pin.coordinate
            if !map.visibleMapRect.contains(MKMapPoint(pin.coordinate)) || map.region.span.latitudeDelta > 5 {
                map.setRegion(MKCoordinateRegion(center: pin.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)), animated: true)
            }
        }

        private func report(_ coordinate: CLLocationCoordinate2D) {
            let location = PinLocation(coordinate)
            reported = location
            parent.pin = location
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let map else { return }
            let point = gesture.location(in: map)
            // A click on the pin itself is the start of a drag, not a request to move it.
            if let view = map.view(for: annotation), view.frame.insetBy(dx: -6, dy: -6).contains(point) { return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            annotation.coordinate = coordinate
            if !map.annotations.contains(where: { $0 === annotation }) { map.addAnnotation(annotation) }
            report(coordinate)
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation === self.annotation else { return nil }
            let id = "photo-location-pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.isDraggable = true
            view.markerTintColor = .systemRed
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending || newState == .canceling, let coordinate = view.annotation?.coordinate else { return }
            view.dragState = .none
            if newState == .ending { report(coordinate) }
        }
    }
}
