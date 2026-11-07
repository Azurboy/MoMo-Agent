import MapKit
import MoMoAgentClient
import SwiftUI

#if os(iOS)
private typealias JourneyMapRepresentable = UIViewRepresentable
private typealias JourneyNativeView = UIView
#else
private typealias JourneyMapRepresentable = NSViewRepresentable
private typealias JourneyNativeView = NSView
#endif

struct LifeIllustrationMapSurface: JourneyMapRepresentable {
    let stops: [IllustrationJourneyStop]
    let legs: [IllustrationJourneyLeg]
    var command: JourneyMapCommand? = nil
    let project: (JourneyProjection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func makeMap(coordinator: Coordinator) -> JourneyMapView {
        let map = JourneyMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        configuration.pointOfInterestFilter = .includingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        map.showsBuildings = true
        map.showsCompass = false
        map.showsScale = false
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.delegate = coordinator
        map.cameraDidInteract = { [weak coordinator] in coordinator?.cameraDidInteract() }
        map.didLayout = { [weak coordinator, weak map] in
            guard let coordinator, let map else { return }
            coordinator.layout(map)
        }
        return map
    }

    #if os(iOS)
    func makeUIView(context: Context) -> JourneyMapView { makeMap(coordinator: context.coordinator) }
    func updateUIView(_ view: JourneyMapView, context: Context) { context.coordinator.update(self, map: view) }
    static func dismantleUIView(_ view: JourneyMapView, coordinator: Coordinator) { coordinator.cancel() }
    #else
    func makeNSView(context: Context) -> JourneyMapView { makeMap(coordinator: context.coordinator) }
    func updateNSView(_ view: JourneyMapView, context: Context) { context.coordinator.update(self, map: view) }
    static func dismantleNSView(_ view: JourneyMapView, coordinator: Coordinator) { coordinator.cancel() }
    #endif

    final class JourneyMapView: MKMapView {
        var didLayout: (() -> Void)?
        var cameraDidInteract: (() -> Void)?
        var hasActiveCameraGesture: Bool { Self.hasActiveGesture(in: self) }

        private static func hasActiveGesture(in view: JourneyNativeView) -> Bool {
            #if os(iOS)
            let gestures = view.gestureRecognizers ?? []
            #else
            let gestures = view.gestureRecognizers
            #endif
            return gestures.contains { $0.state == .began || $0.state == .changed }
                || view.subviews.contains { hasActiveGesture(in: $0) }
        }
        #if os(iOS)
        override func layoutSubviews() { super.layoutSubviews(); didLayout?() }
        #else
        override func layout() { super.layout(); didLayout?() }
        override func scrollWheel(with event: NSEvent) {
            // AppKit wheel scrolling can move MapKit without an active gesture recognizer.
            cameraDidInteract?()
            super.scrollWheel(with: event)
        }
        #endif
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LifeIllustrationMapSurface
        private var signature = ""
        private var lastCommandID: Int?
        private var size = CGSize.zero
        private var cameraCustomized = false
        private var cameraMoving = false
        private var calloutProjection = JourneyCalloutProjection()
        private var isUpdating = false
        private var fitted: [String: [CLLocationCoordinate2D]] = [:]
        private var task: Task<Void, Never>?
        private var graceTask: Task<Void, Never>?
        private var directions: MKDirections?
        private var projectionTask: Task<Void, Never>?
        private var tilesLoaded = false
        private var routesResolved = false
        private var mapFailed = false

        init(parent: LifeIllustrationMapSurface) { self.parent = parent }

        func cameraDidInteract() { cameraCustomized = true }

        func cancel() {
            task?.cancel()
            graceTask?.cancel()
            projectionTask?.cancel()
            directions?.cancel()
        }

        func update(_ parent: LifeIllustrationMapSurface, map: MKMapView) {
            isUpdating = true
            defer { isUpdating = false }
            self.parent = parent
            let signature = parent.stops.flatMap(\.illustrations).map { "\($0.id):\($0.updatedAt)" }.joined(separator: ",")
            if self.signature != signature {
                cancel()
                self.signature = signature
                fitted = [:]
                routesResolved = parent.legs.isEmpty
                cameraCustomized = false
                cameraMoving = false
                calloutProjection = JourneyCalloutProjection()
                size = .zero
                layout(map)
                if !parent.legs.isEmpty {
                    graceTask = Task { [weak self, weak map] in
                        try? await Task.sleep(for: .seconds(2.2))
                        guard let self, !Task.isCancelled, !self.routesResolved else { return }
                        self.routesResolved = true
                        if let map { self.project(map) }
                    }
                }
                task = Task { [weak self, weak map] in
                    guard let self else { return }
                    for leg in parent.legs {
                        if Task.isCancelled { return }
                        let points = leg.coordinates
                        let selected = points.count <= 5 ? points : (0..<5).map { points[$0 * (points.count - 1) / 4] }
                        var coordinates: [CLLocationCoordinate2D] = []
                        for (start, end) in zip(selected, selected.dropFirst()) {
                            let request = MKDirections.Request()
                            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
                            request.transportType = MKMapPoint(start).distance(to: MKMapPoint(end)) < 15_000 ? .walking : .automobile
                            let directions = MKDirections(request: request)
                            self.directions = directions
                            do {
                                let response = try await directions.calculate()
                                guard !Task.isCancelled, let route = response.routes.first else { return }
                                coordinates += (0..<route.polyline.pointCount).map { route.polyline.points()[$0].coordinate }
                            } catch {
                                coordinates = []
                                break
                            }
                        }
                        if !coordinates.isEmpty { fitted[leg.id] = coordinates }
                        if let map { project(map) }
                    }
                    self.directions = nil
                    self.routesResolved = true
                    self.graceTask?.cancel()
                    if let map { project(map) }
                }
            }
            if let command = parent.command, command.id != lastCommandID {
                lastCommandID = command.id
                apply(command.action, to: map)
            }
        }

        private func apply(_ action: JourneyMapCommand.Action, to map: MKMapView) {
            switch action {
            case .zoomIn:
                cameraCustomized = true
                let span = MKCoordinateSpan(
                    latitudeDelta: max(0.0012, map.region.span.latitudeDelta * 0.5),
                    longitudeDelta: max(0.0012, map.region.span.longitudeDelta * 0.5)
                )
                map.setRegion(MKCoordinateRegion(center: map.region.center, span: span), animated: true)
            case .zoomOut:
                cameraCustomized = true
                let span = MKCoordinateSpan(
                    latitudeDelta: min(90.0, map.region.span.latitudeDelta * 2.0),
                    longitudeDelta: min(120.0, map.region.span.longitudeDelta * 2.0)
                )
                map.setRegion(MKCoordinateRegion(center: map.region.center, span: span), animated: true)
            case .fitAll:
                fitAll(map, animated: true)
            }
        }

        private func fitAll(_ map: MKMapView, animated: Bool) {
            guard map.bounds.width > 0, map.bounds.height > 0 else { return }
            let coordinates = parent.stops.compactMap(\.coordinate) + parent.legs.flatMap(\.coordinates)
            var rect = MKMapRect.null
            for coordinate in coordinates {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            guard !rect.isNull else { return }
            let minimum: Double = 1800
            rect = rect.insetBy(dx: -max(0, (minimum - rect.width) / 2), dy: -max(0, (minimum - rect.height) / 2))
            #if os(iOS)
            let padding = UIEdgeInsets(top: 56, left: map.bounds.width * 0.22, bottom: 96, right: map.bounds.width * 0.22)
            #else
            let padding = NSEnginePadding(top: 56, left: map.bounds.width * 0.22, bottom: 96, right: map.bounds.width * 0.22)
            #endif
            cameraCustomized = false
            map.setVisibleMapRect(rect, edgePadding: padding, animated: animated)
            project(map)
        }

        func layout(_ map: MKMapView) {
            guard map.bounds.width > 0, map.bounds.height > 0 else { return }
            if size != map.bounds.size {
                size = map.bounds.size
                calloutProjection = JourneyCalloutProjection()
                if !cameraCustomized {
                    fitAll(map, animated: false)
                    return
                }
            }
            project(map)
        }

        #if !os(iOS)
        private func NSEnginePadding(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> NSEdgeInsets {
            NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        }
        #endif

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            cameraMoving = true
            if (mapView as? JourneyMapView)?.hasActiveCameraGesture == true { cameraCustomized = true }
            project(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            cameraMoving = (mapView as? JourneyMapView)?.hasActiveCameraGesture == true
            project(mapView)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if (mapView as? JourneyMapView)?.hasActiveCameraGesture == true { cameraCustomized = true }
            project(mapView)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if fullyRendered { tilesLoaded = true; mapFailed = false }
            project(mapView)
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
            mapFailed = true
            routesResolved = true
            project(mapView)
        }

        private func project(_ map: MKMapView) {
            var projection = JourneyProjection()
            for stop in parent.stops {
                if let coordinate = stop.coordinate { projection.pins[stop.id] = map.convert(coordinate, toPointTo: map) }
            }
            for leg in parent.legs {
                projection.routes[leg.id] = (fitted[leg.id] ?? leg.coordinates).map { map.convert($0, toPointTo: map) }
            }
            projection.fitted = Set(fitted.keys)
            projection.mapLoaded = tilesLoaded && routesResolved
            projection.mapFailed = mapFailed
            projection.cameraCustomized = cameraCustomized
            calloutProjection.update(pins: projection.pins, cameraCustomized: cameraCustomized, cameraMoving: cameraMoving)
            projection.callouts = calloutProjection
            projectionTask?.cancel()
            if !isUpdating {
                parent.project(projection)
            } else {
                projectionTask = Task { [weak self] in
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    self?.parent.project(projection)
                }
            }
        }
    }
}
