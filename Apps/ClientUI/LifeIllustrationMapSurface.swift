import CoreGraphics
import MapKit
import MoMoAgentClient
import SwiftUI
#if os(iOS)
import UIKit
private typealias JourneyMapRepresentable = UIViewRepresentable
fileprivate typealias JourneyNativeView = UIView
private typealias JourneyNativeFont = UIFont
private typealias JourneyNativeColor = UIColor
#else
import AppKit
private typealias JourneyMapRepresentable = NSViewRepresentable
fileprivate typealias JourneyNativeView = NSView
private typealias JourneyNativeFont = NSFont
private typealias JourneyNativeColor = NSColor
#endif

struct LifeIllustrationMapSurface: JourneyMapRepresentable {
    let stops: [IllustrationJourneyStop]
    let legs: [IllustrationJourneyLeg]
    var cards: [JourneyCallout] = []
    var placeTitles: [String: String] = [:]
    var isDark: Bool = false
    var command: JourneyMapCommand? = nil
    var onSelectStop: (IllustrationJourneyStop) -> Void = { _ in }
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
        map.register(JourneyPebbleAnnotationView.self, forAnnotationViewWithReuseIdentifier: JourneyPebbleAnnotationView.reuseID)
        map.delegate = coordinator
        map.setupDecorationOverlay()
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
    static func dismantleUIView(_ view: JourneyMapView, coordinator: Coordinator) {
        view.stopDisplayLink()
        coordinator.cancel()
    }
    #else
    func makeNSView(context: Context) -> JourneyMapView { makeMap(coordinator: context.coordinator) }
    func updateNSView(_ view: JourneyMapView, context: Context) { context.coordinator.update(self, map: view) }
    static func dismantleNSView(_ view: JourneyMapView, coordinator: Coordinator) { coordinator.cancel() }
    #endif

    final class JourneyMapView: MKMapView {
        var didLayout: (() -> Void)?
        var cameraDidInteract: (() -> Void)?
        fileprivate let decorationView = JourneyScreenDecorationView()
        #if os(iOS)
        private var displayLink: CADisplayLink?
        private final class DisplayLinkProxy {
            weak var target: JourneyMapView?
            init(target: JourneyMapView) { self.target = target }
            @objc func tick() { target?.didLayout?() }
        }
        #endif

        var hasActiveCameraGesture: Bool { Self.hasActiveGesture(in: self) }

        func setupDecorationOverlay() {
            decorationView.frame = bounds
            #if os(iOS)
            decorationView.backgroundColor = .clear
            decorationView.isOpaque = false
            decorationView.isUserInteractionEnabled = false
            decorationView.contentMode = .redraw
            decorationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            #else
            decorationView.wantsLayer = true
            decorationView.layer?.backgroundColor = CGColor.clear
            decorationView.autoresizingMask = [.width, .height]
            #endif
            addSubview(decorationView)
        }

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
        func startDisplayLinkIfNeeded() {
            guard displayLink == nil, window != nil else { return }
            let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopDisplayLink() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if decorationView.frame != bounds { decorationView.frame = bounds }
            if subviews.last !== decorationView { bringSubviewToFront(decorationView) }
            didLayout?()
        }
        #else
        override func layout() {
            super.layout()
            if decorationView.frame != bounds { decorationView.frame = bounds }
            didLayout?()
        }

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
        private var lastOverlaySignature = ""
        private var lastAnnotationSignature = ""
        private var lastCommandID: Int?
        private var size = CGSize.zero
        private var cameraCustomized = false
        private var cameraMoving = false
        private var calloutProjection = JourneyCalloutProjection()
        private var lastPublishedProjection: JourneyProjection?
        private var isUpdating = false
        private var fitted: [String: [CLLocationCoordinate2D]] = [:]
        private var renderedLegs: [RenderedRouteLeg] = []
        private var routeOverlay: JourneyRouteOverlay?
        private weak var routeRenderer: JourneyRouteRenderer?
        private var stopAnnotations: [String: JourneyStopAnnotation] = [:]
        private var lastRenderedLatitudeDelta: Double = 0
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
                lastPublishedProjection = nil
                size = .zero
                rebuildRouteOverlay(on: map, force: true)
                syncAnnotations(on: map)
                layout(map)
                if !parent.legs.isEmpty {
                    graceTask = Task { [weak self, weak map] in
                        try? await Task.sleep(for: .seconds(2.2))
                        guard let self, !Task.isCancelled, !self.routesResolved else { return }
                        self.routesResolved = true
                        if let map { self.project(map, forcePublish: true) }
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
                        if let map {
                            rebuildRouteOverlay(on: map, force: true)
                            syncDecorations(on: map)
                        }
                    }
                    self.directions = nil
                    self.routesResolved = true
                    self.graceTask?.cancel()
                    if let map {
                        rebuildRouteOverlay(on: map, force: true)
                        project(map, forcePublish: true)
                    }
                }
            } else {
                rebuildRouteOverlay(on: map, force: false)
                syncAnnotations(on: map)
                syncDecorations(on: map)
            }
            if let command = parent.command, command.id != lastCommandID {
                lastCommandID = command.id
                apply(command.action, to: map)
            }
        }

        private func rebuildRouteOverlay(on map: MKMapView, force: Bool) {
            let legSig = parent.legs.map { "\($0.id):\(fitted[$0.id]?.count ?? -1):\($0.timeCaption ?? "")" }.joined(separator: "|")
                + "|dark:\(parent.isDark)"
            guard force || legSig != lastOverlaySignature else { return }
            lastOverlaySignature = legSig

            var nextLegs: [RenderedRouteLeg] = []
            nextLegs.reserveCapacity(parent.legs.count)
            for (index, leg) in parent.legs.enumerated() {
                let roadCoords = fitted[leg.id]
                let worldPoints = journeyWorldCurvePoints(
                    roadCoords ?? leg.coordinates,
                    isRoadFitted: roadCoords != nil,
                    seed: index
                )
                guard worldPoints.count >= 2 else { continue }
                let chevron = journeyWorldRouteSample(worldPoints, fraction: 0.52)
                let badgeFractions: [Double] = [0.48, 0.36, 0.64, 0.25, 0.75, 0.18, 0.82]
                let badgeSamples = leg.timeCaption != nil
                    ? badgeFractions.compactMap { journeyWorldRouteSample(worldPoints, fraction: $0) }
                    : []
                nextLegs.append(
                    RenderedRouteLeg(
                        id: leg.id,
                        timeCaption: leg.timeCaption,
                        points: worldPoints,
                        chevronSample: chevron,
                        badgeSamples: badgeSamples
                    )
                )
            }
            renderedLegs = nextLegs
            if let existing = routeOverlay {
                map.removeOverlay(existing)
                routeOverlay = nil
                routeRenderer = nil
            }
            guard !nextLegs.isEmpty else { return }
            let overlay = JourneyRouteOverlay(legs: nextLegs, isDark: parent.isDark)
            routeOverlay = overlay
            lastRenderedLatitudeDelta = map.region.span.latitudeDelta
            map.addOverlay(overlay, level: .aboveLabels)
        }

        private func syncAnnotations(on map: MKMapView) {
            let locatedStops = parent.stops.enumerated().compactMap { idx, stop -> (Int, IllustrationJourneyStop, CLLocationCoordinate2D)? in
                guard let coord = stop.coordinate else { return nil }
                return (idx + 1, stop, coord)
            }
            let sig = locatedStops.map { number, stop, coord in
                let label = parent.placeTitles[stop.id] ?? stop.place ?? stop.stayCaption
                return "\(stop.id):\(number):\(coord.latitude),\(coord.longitude):\(label):\(parent.isDark)"
            }.joined(separator: "|")
            guard sig != lastAnnotationSignature else { return }
            lastAnnotationSignature = sig

            let validIDs = Set(locatedStops.map { $0.1.id })
            let removed = stopAnnotations.filter { !validIDs.contains($0.key) }
            if !removed.isEmpty {
                map.removeAnnotations(Array(removed.values))
                for key in removed.keys { stopAnnotations.removeValue(forKey: key) }
            }
            var toAdd: [JourneyStopAnnotation] = []
            for (number, stop, coord) in locatedStops {
                let label = parent.placeTitles[stop.id] ?? stop.place ?? stop.stayCaption
                if let existing = stopAnnotations[stop.id] {
                    if existing.coordinate.latitude != coord.latitude || existing.coordinate.longitude != coord.longitude {
                        existing.coordinate = coord
                    }
                    let appearanceChanged = existing.number != number || existing.isDark != parent.isDark || existing.labelText != label
                    existing.number = number
                    existing.isDark = parent.isDark
                    existing.labelText = label
                    if appearanceChanged, let view = map.view(for: existing) as? JourneyPebbleAnnotationView {
                        view.configure(with: existing) { [weak self] in self?.selectStop(id: stop.id) }
                    }
                } else {
                    let annotation = JourneyStopAnnotation(stopID: stop.id, coordinate: coord, number: number, labelText: label, isDark: parent.isDark)
                    stopAnnotations[stop.id] = annotation
                    toAdd.append(annotation)
                }
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }
        }

        private func selectStop(id: String) {
            guard let stop = parent.stops.first(where: { $0.id == id }) else { return }
            parent.onSelectStop(stop)
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
                project(map, forcePublish: true)
            case .zoomOut:
                cameraCustomized = true
                let span = MKCoordinateSpan(
                    latitudeDelta: min(90.0, map.region.span.latitudeDelta * 2.0),
                    longitudeDelta: min(120.0, map.region.span.longitudeDelta * 2.0)
                )
                map.setRegion(MKCoordinateRegion(center: map.region.center, span: span), animated: true)
                project(map, forcePublish: true)
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
            project(map, forcePublish: true)
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
                project(map, forcePublish: true)
                return
            }
            syncDecorations(on: map)
            if !cameraMoving {
                project(map, forcePublish: false)
            }
        }

        #if !os(iOS)
        private func NSEnginePadding(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) -> NSEdgeInsets {
            NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        }
        #endif

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let routeOverlay = overlay as? JourneyRouteOverlay {
                let renderer = JourneyRouteRenderer(routeOverlay: routeOverlay)
                self.routeRenderer = renderer
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let stopAnnotation = annotation as? JourneyStopAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(
                withIdentifier: JourneyPebbleAnnotationView.reuseID,
                for: stopAnnotation
            ) as? JourneyPebbleAnnotationView) ?? JourneyPebbleAnnotationView(
                annotation: stopAnnotation,
                reuseIdentifier: JourneyPebbleAnnotationView.reuseID
            )
            let stopID = stopAnnotation.stopID
            view.configure(with: stopAnnotation) { [weak self] in
                self?.selectStop(id: stopID)
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let annotation = view.annotation {
                mapView.deselectAnnotation(annotation, animated: false)
            }
            if let stopAnnotation = view.annotation as? JourneyStopAnnotation {
                selectStop(id: stopAnnotation.stopID)
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            cameraMoving = true
            let wasCustomized = cameraCustomized
            if (mapView as? JourneyMapView)?.hasActiveCameraGesture == true { cameraCustomized = true }
            #if os(iOS)
            (mapView as? JourneyMapView)?.startDisplayLinkIfNeeded()
            #endif
            syncDecorations(on: mapView)
            if cameraCustomized != wasCustomized || calloutProjection.pins.isEmpty {
                project(mapView, forcePublish: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let stillGestureActive = (mapView as? JourneyMapView)?.hasActiveCameraGesture == true
            cameraMoving = stillGestureActive
            #if os(iOS)
            if !stillGestureActive { (mapView as? JourneyMapView)?.stopDisplayLink() }
            #endif
            if !stillGestureActive {
                let currentSpan = max(1e-7, mapView.region.span.latitudeDelta)
                let prevSpan = max(1e-7, lastRenderedLatitudeDelta)
                if abs(log2(currentSpan / prevSpan)) > 0.06 {
                    lastRenderedLatitudeDelta = currentSpan
                    routeRenderer?.setNeedsDisplay()
                }
            }
            syncDecorations(on: mapView)
            project(mapView, forcePublish: !stillGestureActive)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let wasCustomized = cameraCustomized
            if (mapView as? JourneyMapView)?.hasActiveCameraGesture == true { cameraCustomized = true }
            syncDecorations(on: mapView)
            if cameraCustomized != wasCustomized || calloutProjection.pins.isEmpty {
                project(mapView, forcePublish: true)
            }
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if fullyRendered { tilesLoaded = true; mapFailed = false }
            syncDecorations(on: mapView)
            project(mapView, forcePublish: true)
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
            mapFailed = true
            routesResolved = true
            syncDecorations(on: mapView)
            project(mapView, forcePublish: true)
        }

        private func currentPins(on map: MKMapView) -> [String: CGPoint] {
            var pins: [String: CGPoint] = [:]
            pins.reserveCapacity(parent.stops.count)
            for stop in parent.stops {
                if let coordinate = stop.coordinate {
                    pins[stop.id] = map.convert(coordinate, toPointTo: map)
                }
            }
            return pins
        }

        func syncDecorations(on map: MKMapView) {
            guard let journeyMap = map as? JourneyMapView, map.bounds.width > 0, map.bounds.height > 0 else { return }
            let pins = currentPins(on: map)
            let legBadges: [JourneyScreenDecorationView.LegBadgeSamples] = renderedLegs.compactMap { leg in
                guard let caption = leg.timeCaption, !leg.badgeSamples.isEmpty else { return nil }
                let samples = leg.badgeSamples.map { sample in
                    let screenPt = map.convert(sample.point.coordinate, toPointTo: journeyMap.decorationView)
                    return (point: screenPt, angle: CGFloat(sample.angle))
                }
                return JourneyScreenDecorationView.LegBadgeSamples(caption: caption, samples: samples)
            }
            journeyMap.decorationView.update(
                pins: pins,
                cards: parent.cards,
                legBadges: legBadges,
                isDark: parent.isDark
            )
        }

        private func project(_ map: MKMapView, forcePublish: Bool) {
            let pins = currentPins(on: map)
            calloutProjection.update(pins: pins, cameraCustomized: cameraCustomized, cameraMoving: cameraMoving)
            var projection = JourneyProjection()
            projection.pins = calloutProjection.pins.isEmpty ? pins : (cameraMoving ? calloutProjection.pins : pins)
            projection.callouts = calloutProjection
            projection.mapLoaded = tilesLoaded && routesResolved
            projection.mapFailed = mapFailed
            projection.cameraCustomized = cameraCustomized

            guard forcePublish || !cameraMoving else { return }
            guard projection != lastPublishedProjection else { return }
            lastPublishedProjection = projection

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

// MARK: - World-Locked Native Route Overlay & Renderer

private struct RenderedRouteLeg: Sendable {
    let id: String
    let timeCaption: String?
    let points: [MKMapPoint]
    let chevronSample: (point: MKMapPoint, angle: Double)?
    let badgeSamples: [(point: MKMapPoint, angle: Double)]
}

private final class JourneyRouteOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect = .world
    let legs: [RenderedRouteLeg]
    let isDark: Bool

    init(legs: [RenderedRouteLeg], isDark: Bool) {
        self.legs = legs
        self.isDark = isDark
        self.coordinate = legs.first?.points.first?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        super.init()
    }
}

private final class JourneyRouteRenderer: MKOverlayRenderer {
    private let legs: [RenderedRouteLeg]
    private let isDark: Bool

    init(routeOverlay: JourneyRouteOverlay) {
        self.legs = routeOverlay.legs
        self.isDark = routeOverlay.isDark
        super.init(overlay: routeOverlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard zoomScale > 0, !legs.isEmpty else { return }
        let invScale = 1.0 / CGFloat(zoomScale)
        let casingColor = JourneySurfaceColors.routeCasing(isDark: isDark)
        let ribbonColor = JourneySurfaceColors.routeRibbon(isDark: isDark)
        let chevronColor = JourneySurfaceColors.pinRim(isDark: isDark)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for leg in legs where leg.points.count >= 2 {
            let path = CGMutablePath()
            path.move(to: point(for: leg.points[0]))
            for idx in 1..<leg.points.count {
                path.addLine(to: point(for: leg.points[idx]))
            }

            context.addPath(path)
            context.setStrokeColor(casingColor)
            context.setLineWidth(8.2 * invScale)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(ribbonColor)
            context.setLineWidth(3.6 * invScale)
            context.strokePath()

            if let sample = leg.chevronSample {
                let mid = point(for: sample.point)
                let angle = CGFloat(sample.angle)
                let arm = 5.0 * invScale
                let tip = 1.5 * invScale
                let chevron = CGMutablePath()
                chevron.move(to: CGPoint(x: mid.x - arm * cos(angle - 0.62), y: mid.y - arm * sin(angle - 0.62)))
                chevron.addLine(to: CGPoint(x: mid.x + tip * cos(angle), y: mid.y + tip * sin(angle)))
                chevron.addLine(to: CGPoint(x: mid.x - arm * cos(angle + 0.62), y: mid.y - arm * sin(angle + 0.62)))
                context.addPath(chevron)
                context.setStrokeColor(chevronColor)
                context.setLineWidth(1.5 * invScale)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}

// MARK: - Native Ceramic Pebble Stop Annotations

private final class JourneyStopAnnotation: NSObject, MKAnnotation {
    let stopID: String
    dynamic var coordinate: CLLocationCoordinate2D
    var number: Int
    var labelText: String
    var isDark: Bool

    init(stopID: String, coordinate: CLLocationCoordinate2D, number: Int, labelText: String, isDark: Bool) {
        self.stopID = stopID
        self.coordinate = coordinate
        self.number = number
        self.labelText = labelText
        self.isDark = isDark
        super.init()
    }
}

private final class JourneyPebbleAnnotationView: MKAnnotationView {
    static let reuseID = "JourneyPebbleAnnotationView"
    private var onTap: (() -> Void)?
    private var renderedKey: String?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        displayPriority = .required
        zPriority = .max
        collisionMode = .none
        centerOffset = .zero
        frame = CGRect(x: 0, y: 0, width: 32, height: 28)
        #if os(iOS)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        #else
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleTap)))
        #endif
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("unavailable") }

    @objc private func handleTap() {
        onTap?()
    }

    func configure(with stop: JourneyStopAnnotation, onTap: @escaping () -> Void) {
        self.annotation = stop
        self.onTap = onTap
        #if os(iOS)
        self.accessibilityIdentifier = "lifeIllustration.map.pin.\(stop.stopID)"
        self.accessibilityLabel = stop.labelText
        let scale = window?.screen.scale ?? traitCollection.displayScale
        #else
        self.setAccessibilityIdentifier("lifeIllustration.map.pin.\(stop.stopID)")
        self.setAccessibilityLabel(stop.labelText)
        let scale = window?.backingScaleFactor ?? 2.0
        #endif
        let effectiveScale = max(2.0, scale)
        let key = "\(stop.number):\(stop.isDark):\(effectiveScale)"
        guard renderedKey != key else { return }
        renderedKey = key
        image = Self.renderPebbleImage(number: stop.number, isDark: stop.isDark, scale: effectiveScale)
    }

    #if os(iOS)
    private static func renderPebbleImage(number: Int, isDark: Bool, scale: CGFloat) -> UIImage {
        let size = CGSize(width: 32, height: 28)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            drawPebble(in: ctx.cgContext, size: size, number: number, isDark: isDark)
        }
    }
    #else
    private static func renderPebbleImage(number: Int, isDark: Bool, scale: CGFloat) -> NSImage {
        let size = CGSize(width: 32, height: 28)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawPebble(in: ctx, size: rect.size, number: number, isDark: isDark)
            return true
        }
        return image
    }
    #endif

    private static func drawPebble(in context: CGContext, size: CGSize, number: Int, isDark: Bool) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let pinRect = CGRect(x: center.x - 13, y: center.y - 11, width: 26, height: 22)
        let shadowRect = pinRect.offsetBy(dx: 0, dy: 1.8)
        let shadowPath = JourneyPebble().path(in: shadowRect).cgPath
        let pebblePath = JourneyPebble().path(in: pinRect).cgPath

        context.saveGState()
        context.addPath(shadowPath)
        context.setFillColor(CGColor(gray: 0, alpha: isDark ? 0.34 : 0.14))
        context.fillPath()

        context.addPath(pebblePath)
        context.setFillColor(JourneySurfaceColors.pinFill(isDark: isDark))
        context.fillPath()

        context.addPath(pebblePath)
        context.setStrokeColor(JourneySurfaceColors.pinRim(isDark: isDark))
        context.setLineWidth(1.8)
        context.strokePath()

        let text = "\(number)" as NSString
        let font = JourneyNativeFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: JourneySurfaceColors.nativePinText(isDark: isDark)
        ]
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = CGPoint(x: center.x - textSize.width * 0.5, y: center.y - textSize.height * 0.5)
        text.draw(at: textOrigin, withAttributes: attrs)
        context.restoreGState()
    }
}

// MARK: - Synchronous Screen-Space Card Connectors & Transit Badges

fileprivate final class JourneyScreenDecorationView: JourneyNativeView {
    struct LegBadgeSamples {
        let caption: String
        let samples: [(point: CGPoint, angle: CGFloat)]
    }

    private var pins: [String: CGPoint] = [:]
    private var cards: [JourneyCallout] = []
    private var legBadges: [LegBadgeSamples] = []
    private var isDark = false

    #if os(iOS)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    #else
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    func update(
        pins: [String: CGPoint],
        cards: [JourneyCallout],
        legBadges: [LegBadgeSamples],
        isDark: Bool
    ) {
        self.pins = pins
        self.cards = cards
        self.legBadges = legBadges
        self.isDark = isDark
        #if os(iOS)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    override func draw(_ rect: CGRect) {
        #if os(iOS)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #endif
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let casingColor = JourneySurfaceColors.routeCasing(isDark: isDark)
        let stemCasingColor = JourneySurfaceColors.routeCasing(isDark: isDark, alphaMultiplier: 0.85)
        let stemColor = JourneySurfaceColors.connectorStem(isDark: isDark)
        let pinFill = JourneySurfaceColors.pinFill(isDark: isDark)
        let pinRim = JourneySurfaceColors.pinRim(isDark: isDark)
        let cardFill = JourneySurfaceColors.cardFill(isDark: isDark)
        let cardBorder = JourneySurfaceColors.cardBorder(isDark: isDark)
        let badgeFont = JourneyNativeFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        let badgeTextColor = JourneySurfaceColors.nativeCardInk(isDark: isDark)

        // 1. Compact transit time pills hugging the world-anchored route
        var placedBadges: [CGRect] = []
        for leg in legBadges {
            var chosen: (badgeCenter: CGPoint, routeAnchor: CGPoint)?
            outer: for sample in leg.samples {
                let anchor = sample.point
                let nx = -sin(sample.angle), ny = cos(sample.angle)
                for offset: CGFloat in [0, 26, -26, 48, -48, 72, -72, 96, -96] {
                    let candidate = CGPoint(
                        x: min(size.width - 52, max(52, anchor.x + nx * offset)),
                        y: min(size.height - 24, max(16, anchor.y + ny * offset))
                    )
                    let hitRect = CGRect(x: candidate.x - 48, y: candidate.y - 12, width: 96, height: 24)
                    let clearOfCards = !cards.contains { $0.frame.insetBy(dx: -4, dy: -4).intersects(hitRect) }
                    let clearOfBadges = !placedBadges.contains { $0.insetBy(dx: -6, dy: -4).intersects(hitRect) }
                    let clearOfPins = !pins.values.contains { hitRect.insetBy(dx: -12, dy: -10).contains($0) }
                    if clearOfCards && clearOfBadges && clearOfPins {
                        chosen = (candidate, anchor)
                        break outer
                    }
                }
            }
            guard let chosen else { continue }
            let pill = CGRect(x: chosen.badgeCenter.x - 46, y: chosen.badgeCenter.y - 10, width: 92, height: 20)
            placedBadges.append(pill)
            let dist = hypot(chosen.badgeCenter.x - chosen.routeAnchor.x, chosen.badgeCenter.y - chosen.routeAnchor.y)
            if dist > 10 {
                let mid = CGPoint(
                    x: (chosen.routeAnchor.x + chosen.badgeCenter.x) * 0.5 - (chosen.badgeCenter.y - chosen.routeAnchor.y) * 0.22,
                    y: (chosen.routeAnchor.y + chosen.badgeCenter.y) * 0.5 + (chosen.badgeCenter.x - chosen.routeAnchor.x) * 0.22
                )
                let stem = CGMutablePath()
                stem.move(to: chosen.routeAnchor)
                stem.addQuadCurve(to: chosen.badgeCenter, control: mid)
                context.saveGState()
                context.setLineCap(.round)
                context.addPath(stem)
                context.setStrokeColor(casingColor)
                context.setLineWidth(2.8)
                context.strokePath()
                context.addPath(stem)
                context.setStrokeColor(stemColor)
                context.setLineWidth(1.2)
                context.strokePath()
                context.restoreGState()
            }
            let pillPath = CGPath(roundedRect: pill, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.saveGState()
            context.addPath(pillPath)
            context.setFillColor(cardFill)
            context.fillPath()
            context.addPath(pillPath)
            context.setStrokeColor(cardBorder)
            context.setLineWidth(0.8)
            context.strokePath()
            let caption = leg.caption as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: badgeTextColor]
            let textSize = caption.size(withAttributes: attrs)
            caption.draw(
                at: CGPoint(x: chosen.badgeCenter.x - textSize.width * 0.5, y: chosen.badgeCenter.y - textSize.height * 0.5),
                withAttributes: attrs
            )
            context.restoreGState()
        }

        // 2. Delicate graphite S-curve stems clipped outside the native pebble annotations
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
        for card in cards {
            guard let pin = pins[card.id], viewport.contains(pin) else { continue }
            let connector = journeyCardConnector(pin: pin, frame: card.frame, right: card.right)
            let pinCutout = JourneyPebble().path(in: CGRect(x: pin.x - 13.5, y: pin.y - 11.5, width: 27, height: 23)).cgPath

            context.saveGState()
            let clipPath = CGMutablePath()
            clipPath.addRect(bounds.insetBy(dx: -64, dy: -64))
            clipPath.addPath(pinCutout)
            context.addPath(clipPath)
            context.clip(using: .evenOdd)

            context.setLineCap(.round)
            context.addPath(connector.path.cgPath)
            context.setStrokeColor(stemCasingColor)
            context.setLineWidth(3.2)
            context.strokePath()

            context.addPath(connector.path.cgPath)
            context.setStrokeColor(stemColor)
            context.setLineWidth(1.4)
            context.strokePath()
            context.restoreGState()

            let dotRect = CGRect(x: connector.anchor.x - 2.6, y: connector.anchor.y - 2.6, width: 5.2, height: 5.2)
            context.saveGState()
            context.setFillColor(pinFill)
            context.fillEllipse(in: dotRect)
            context.setStrokeColor(pinRim)
            context.setLineWidth(1.0)
            context.strokeEllipse(in: dotRect)
            context.restoreGState()
        }
    }
}

private enum JourneySurfaceColors {
    static func routeCasing(isDark: Bool, alphaMultiplier: CGFloat = 1.0) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.095, green: 0.090, blue: 0.084, alpha: 0.92 * alphaMultiplier)
            : CGColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 0.94 * alphaMultiplier)
    }

    static func routeRibbon(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.925, green: 0.902, blue: 0.855, alpha: 1.0)
            : CGColor(srgbRed: 0.175, green: 0.162, blue: 0.146, alpha: 1.0)
    }

    static func connectorStem(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.88, green: 0.85, blue: 0.80, alpha: 0.62)
            : CGColor(srgbRed: 0.22, green: 0.20, blue: 0.18, alpha: 0.60)
    }

    static func pinFill(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.935, green: 0.914, blue: 0.872, alpha: 1.0)
            : CGColor(srgbRed: 0.145, green: 0.136, blue: 0.125, alpha: 1.0)
    }

    static func pinRim(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1.0)
            : CGColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 1.0)
    }

    static func cardFill(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.148, green: 0.143, blue: 0.136, alpha: 0.95)
            : CGColor(srgbRed: 0.992, green: 0.988, blue: 0.976, alpha: 0.96)
    }

    static func cardBorder(isDark: Bool) -> CGColor {
        isDark
            ? CGColor(srgbRed: 0.94, green: 0.92, blue: 0.88, alpha: 0.14)
            : CGColor(srgbRed: 0.14, green: 0.13, blue: 0.11, alpha: 0.13)
    }

    static func nativePinText(isDark: Bool) -> JourneyNativeColor {
        isDark
            ? JourneyNativeColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)
            : JourneyNativeColor(red: 0.985, green: 0.978, blue: 0.960, alpha: 1.0)
    }

    static func nativeCardInk(isDark: Bool) -> JourneyNativeColor {
        isDark
            ? JourneyNativeColor(red: 0.965, green: 0.953, blue: 0.930, alpha: 1.0)
            : JourneyNativeColor(red: 0.105, green: 0.100, blue: 0.094, alpha: 1.0)
    }
}
