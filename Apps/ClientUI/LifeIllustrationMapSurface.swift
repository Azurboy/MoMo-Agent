import MapKit
import MoMoAgentClient
import SwiftUI

#if os(iOS)
private typealias JourneyMapRepresentable = UIViewRepresentable
#else
private typealias JourneyMapRepresentable = NSViewRepresentable
#endif

struct LifeIllustrationMapSurface: JourneyMapRepresentable {
    let items: [LifeIllustration]
    let legs: [IllustrationJourneyLeg]
    let project: (JourneyProjection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func makeMap(coordinator: Coordinator) -> JourneyMapView {
        let map = JourneyMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        map.showsBuildings = true
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.delegate = coordinator
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
        #if os(iOS)
        override func layoutSubviews() { super.layoutSubviews(); didLayout?() }
        #else
        override func layout() { super.layout(); didLayout?() }
        #endif
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LifeIllustrationMapSurface
        private var signature = ""
        private var size = CGSize.zero
        private var fitted: [String: [CLLocationCoordinate2D]] = [:]
        private var task: Task<Void, Never>?
        private var graceTask: Task<Void, Never>?
        private var directions: MKDirections?
        private var projectionTask: Task<Void, Never>?
        private var tilesLoaded = false
        private var routesResolved = false
        private var mapFailed = false

        init(parent: LifeIllustrationMapSurface) { self.parent = parent }

        func cancel() {
            task?.cancel()
            graceTask?.cancel()
            projectionTask?.cancel()
            directions?.cancel()
        }

        func update(_ parent: LifeIllustrationMapSurface, map: MKMapView) {
            self.parent = parent
            let signature = parent.items.map { "\($0.id):\($0.updatedAt)" }.joined(separator: ",")
            if self.signature != signature {
                cancel()
                self.signature = signature
                fitted = [:]
                routesResolved = parent.legs.isEmpty
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
        }

        func layout(_ map: MKMapView) {
            guard map.bounds.width > 0, map.bounds.height > 0 else { return }
            if size != map.bounds.size {
                size = map.bounds.size
                let coordinates = parent.items.compactMap(\.coordinate) + parent.legs.flatMap(\.coordinates)
                var rect = MKMapRect.null
                for coordinate in coordinates {
                    let point = MKMapPoint(coordinate)
                    rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
                }
                if !rect.isNull {
                    let minimum: Double = 2400
                    rect = rect.insetBy(dx: -max(0, (minimum - rect.width) / 2), dy: -max(0, (minimum - rect.height) / 2))
                    #if os(iOS)
                    let padding = UIEdgeInsets(top: 64, left: size.width * 0.25, bottom: 132, right: size.width * 0.25)
                    #else
                    let padding = NSEdgeInsets(top: 64, left: size.width * 0.25, bottom: 132, right: size.width * 0.25)
                    #endif
                    map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
                }
            }
            project(map)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { project(mapView) }

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
            for item in parent.items {
                if let coordinate = item.coordinate { projection.pins[item.id] = map.convert(coordinate, toPointTo: map) }
            }
            for leg in parent.legs {
                projection.routes[leg.id] = (fitted[leg.id] ?? leg.coordinates).map { map.convert($0, toPointTo: map) }
            }
            projection.fitted = Set(fitted.keys)
            projection.mapLoaded = tilesLoaded && routesResolved
            projection.mapFailed = mapFailed
            projectionTask?.cancel()
            projectionTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.parent.project(projection)
            }
        }
    }
}
