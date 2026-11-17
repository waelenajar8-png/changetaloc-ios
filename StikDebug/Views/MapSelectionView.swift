//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum RouteSearchField {
    case start
    case end
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
    static let importedRouteFallbackSpeedMetersPerSecond: CLLocationSpeed = 13.4
    /// Au-delà, on ne charge plus les limitations rue par rue : la zone à couvrir serait trop grande
    /// et le trajet resterait bloqué sur « Chargement des vitesses ».
    static let speedLimitLookupMaxDistance: CLLocationDistance = 20_000
    /// Nombre de points visé pour dessiner un long trajet sans alourdir la carte.
    static let maximumDisplayPointCount: Double = 4_000
    static let customSpeedRangeKmh: ClosedRange<Double> = 1...2_000
    static let customSpeedSliderMaxKmh: Double = 300
}

/// Façon de se déplacer le long d'un trajet. Fixe la vitesse et le type d'itinéraire.
private enum TravelMode: String, CaseIterable, Identifiable {
    case walk, bike, moto, car, train, custom, boat, plane

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "À pied"
        case .bike: return "Vélo"
        case .moto: return "Moto"
        case .car: return "Voiture"
        case .train: return "Train"
        case .custom: return "Vitesse libre"
        case .boat: return "Bateau"
        case .plane: return "Avion"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .moto: return "scooter"
        case .car: return "car.fill"
        case .train: return "tram.fill"
        case .custom: return "speedometer"
        case .boat: return "ferry.fill"
        case .plane: return "airplane"
        }
    }

    /// Le bateau et l'avion vont en ligne droite ; les autres suivent les grands axes terrestres
    /// (le train suit l'itinéraire terrestre, qui longe le plus souvent les voies ferrées).
    var followsRoads: Bool {
        self != .boat && self != .plane
    }

    var transportType: MKDirectionsTransportType {
        (self == .walk || self == .bike) ? .walking : .automobile
    }

    /// Train, avion et bateau partent d'une gare, d'un aéroport ou d'un port.
    var hubKind: TransportHubKind? {
        switch self {
        case .train: return .station
        case .plane: return .airport
        case .boat: return .port
        default: return nil
        }
    }

    /// Vitesse moyenne affichée sous les modes, pour que le client sache à quoi s'attendre.
    func speedHint(customKmh: Double) -> String {
        switch self {
        case .walk: return "5 km/h"
        case .bike: return "18 km/h"
        case .moto, .car: return "Vitesse des routes"
        case .train: return "200 km/h"
        case .custom: return "\(Int(customKmh)) km/h"
        case .boat: return "40 km/h"
        case .plane: return "850 km/h"
        }
    }

    /// Vitesse imposée en mètres par seconde. `nil` : on suit la limitation de chaque route.
    func fixedSpeed(customKmh: Double) -> CLLocationSpeed? {
        switch self {
        case .walk: return 5.0 / 3.6
        case .bike: return 18.0 / 3.6
        case .moto: return nil
        case .car: return nil
        case .train: return 200.0 / 3.6
        case .custom: return min(max(customKmh, 1.0), RouteSimulationDefaults.customSpeedRangeKmh.upperBound) / 3.6
        case .boat: return 40.0 / 3.6
        case .plane: return 850.0 / 3.6
        }
    }
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
}

// MARK: - Trajet complet : rejoindre la gare, l'aéroport ou le port, voyager, puis finir le trajet.

/// Moyen utilisé pour rejoindre la gare (ou l'aéroport, le port) et pour en repartir.
private enum AccessMode: String, CaseIterable, Identifiable {
    case walk, bike, car

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "À pied"
        case .bike: return "Vélo"
        case .car: return "Voiture"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .car: return "car.fill"
        }
    }

    var transportType: MKDirectionsTransportType {
        self == .car ? .automobile : .walking
    }

    /// `nil` : la voiture roule à la vitesse moyenne de l'itinéraire calculé par Plans.
    var fixedSpeed: CLLocationSpeed? {
        switch self {
        case .walk: return 5.0 / 3.6
        case .bike: return 18.0 / 3.6
        case .car: return nil
        }
    }
}

private enum TransportHubKind {
    case station, airport, port

    /// « Passer par la gare », « Rejoindre l'aéroport »…
    var article: String {
        switch self {
        case .station: return "la gare"
        case .airport: return "l'aéroport"
        case .port: return "le port"
        }
    }

    var noun: String {
        switch self {
        case .station: return "gare"
        case .airport: return "aéroport"
        case .port: return "port"
        }
    }

    var notFound: String {
        switch self {
        case .station: return "Aucune gare trouvée"
        case .airport: return "Aucun aéroport trouvé"
        case .port: return "Aucun port trouvé"
        }
    }

    var nearSame: String {
        switch self {
        case .station: return "de la même gare"
        case .airport: return "du même aéroport"
        case .port: return "du même port"
        }
    }

    var systemImage: String {
        switch self {
        case .station: return "tram.fill"
        case .airport: return "airplane"
        case .port: return "ferry.fill"
        }
    }

    var queries: [String] {
        switch self {
        case .station: return ["gare", "train station"]
        case .airport: return ["aéroport", "airport"]
        case .port: return ["gare maritime", "ferry terminal", "port"]
        }
    }

    var categories: [MKPointOfInterestCategory]? {
        switch self {
        case .airport: return [.airport]
        default: return nil
        }
    }

    /// Distance maximale à laquelle on cherche le point de passage autour du départ ou de l'arrivée.
    var searchRadius: CLLocationDistance {
        switch self {
        case .station: return 60_000
        case .airport: return 250_000
        case .port: return 150_000
        }
    }

    /// Écarte les résultats qui ne conviennent pas (gare routière, aérodrome de loisirs…).
    func accepts(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let rejected: [String]
        switch self {
        case .station: rejected = ["routière", "bus", "parking", "police", "service", "péage", "essence"]
        case .airport: rejected = ["aérodrome", "aerodrome", "airfield", "héliport", "heliport", "aéroclub", "aeroclub", "parking", "hôtel", "hotel"]
        case .port: rejected = ["parking", "hôtel", "hotel"]
        }
        return !rejected.contains { lowered.contains($0) }
    }

    /// En dessous de cette distance, on considère que le point est déjà sur place.
    static let alreadyThereDistance: CLLocationDistance = 400
}

private struct TransportHub {
    let name: String
    let coordinate: CLLocationCoordinate2D
    let systemImage: String
}

private struct JourneyLeg: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let duration: TimeInterval
}

private struct JourneyPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let samples: [RoutePlaybackSample]
    let distance: CLLocationDistance
    let duration: TimeInterval
    let legs: [JourneyLeg]
    let hubs: [TransportHub]
    let notes: [String]
}

private func straightDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

/// Cherche la gare, l'aéroport ou le port le plus proche d'un point.
private func findNearestHub(_ kind: TransportHubKind, near coordinate: CLLocationCoordinate2D) async -> TransportHub? {
    var best: (hub: TransportHub, distance: CLLocationDistance)?
    for query in kind.queries {
        if Task.isCancelled { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: kind.searchRadius * 2,
            longitudinalMeters: kind.searchRadius * 2
        )
        request.resultTypes = .pointOfInterest
        if let categories = kind.categories {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { continue }
        for item in response.mapItems {
            let hubCoordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(hubCoordinate) else { continue }
            let name = item.name ?? kind.noun.capitalized
            guard kind.accepts(name) else { continue }
            let distance = straightDistance(coordinate, hubCoordinate)
            guard distance <= kind.searchRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (TransportHub(name: name, coordinate: hubCoordinate, systemImage: kind.systemImage), distance)
            }
        }
    }
    return best?.hub
}

/// Une étape du trajet : ses points, sa distance et sa vitesse.
private struct JourneySegment {
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let speed: CLLocationSpeed
}

/// Étape sur route (à pied, à vélo ou en voiture), calculée par Plans.
private func roadSegment(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    transportType: MKDirectionsTransportType,
    fixedSpeed: CLLocationSpeed?
) async throws -> JourneySegment {
    func request(_ type: MKDirectionsTransportType) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.requestsAlternateRoutes = false
        request.transportType = type
        return request
    }

    let response: MKDirections.Response
    do {
        response = try await MKDirections(request: request(transportType)).calculate()
    } catch {
        // Plans ne donne pas toujours d'itinéraire piéton sur une longue distance : on suit alors la route.
        guard transportType == .walking, !Task.isCancelled else { throw error }
        response = try await MKDirections(request: request(.automobile)).calculate()
    }
    guard let route = response.routes.first else {
        throw NSError(domain: "RouteSimulation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aucun itinéraire trouvé."])
    }
    let coordinates = sampledRouteCoordinates(
        from: route.polyline.coordinateArray,
        targetDistance: max(
            RouteSimulationDefaults.pathSamplingDistance,
            route.distance / RouteSimulationDefaults.maximumDisplayPointCount
        )
    )
    let averageSpeed = route.expectedTravelTime > 0 ? route.distance / route.expectedTravelTime : 13.4
    return JourneySegment(coordinates: coordinates, distance: route.distance, speed: fixedSpeed ?? averageSpeed)
}

/// Étape en ligne droite (bateau) ou en arc de grand cercle (avion).
private func directSegment(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    greatCircle: Bool,
    speed: CLLocationSpeed
) -> JourneySegment {
    let distance = straightDistance(start, end)
    let spacing = max(RouteSimulationDefaults.pathSamplingDistance, distance / 2000)
    let coordinates = greatCircle
        ? greatCircleCoordinates(from: start, to: end, pointCount: Int(ceil(distance / spacing)))
        : sampledRouteCoordinates(from: [start, end], targetDistance: spacing)
    return JourneySegment(coordinates: coordinates, distance: distance, speed: speed)
}

/// Trajet complet : départ → gare (à pied, à vélo ou en voiture) → train → gare d'arrivée → destination.
/// Même principe avec l'aéroport pour l'avion et le port pour le bateau.
private func buildJourneyPlan(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    mainMode: TravelMode,
    kind: TransportHubKind,
    access: AccessMode
) async throws -> JourneyPlan {
    async let startHubSearch = findNearestHub(kind, near: start)
    async let endHubSearch = findNearestHub(kind, near: end)
    let startHub = await startHubSearch
    let endHub = await endHubSearch
    try Task.checkCancellation()

    var notes: [String] = []
    var hubs: [TransportHub] = []
    var segments: [(leg: (title: String, image: String), segment: JourneySegment)] = []

    // Départ et arrivée autour de la même gare : le train n'a pas de sens, on y va directement.
    if let startHub, let endHub, straightDistance(startHub.coordinate, endHub.coordinate) < 2_000 {
        let segment = try await roadSegment(from: start, to: end, transportType: access.transportType, fixedSpeed: access.fixedSpeed)
        notes.append("Le départ et l'arrivée sont proches \(kind.nearSame) : trajet direct, \(access.title.lowercased()).")
        segments.append((leg: (title: access.title, image: access.systemImage), segment: segment))
    } else {
        let mainStart = startHub?.coordinate ?? start
        let mainEnd = endHub?.coordinate ?? end
        if startHub == nil {
            notes.append("\(kind.notFound) près du départ : le trajet part directement de ton point de départ.")
        }
        if endHub == nil {
            notes.append("\(kind.notFound) près de l'arrivée : le trajet arrive directement à destination.")
        }

        // 1. Rejoindre la gare, l'aéroport ou le port.
        if let startHub {
            hubs.append(startHub)
            if straightDistance(start, startHub.coordinate) > TransportHubKind.alreadyThereDistance {
                let segment = try await roadSegment(from: start, to: startHub.coordinate, transportType: access.transportType, fixedSpeed: access.fixedSpeed)
                segments.append((leg: (title: access.title, image: access.systemImage), segment: segment))
            }
        }

        // 2. Le voyage principal.
        try Task.checkCancellation()
        let mainSpeed = mainMode.fixedSpeed(customKmh: 50) ?? 13.4
        let mainSegment: JourneySegment
        switch kind {
        case .station:
            // Le train suit les grands axes terrestres, qui longent le plus souvent les voies ferrées.
            if let segment = try? await roadSegment(from: mainStart, to: mainEnd, transportType: .automobile, fixedSpeed: mainSpeed) {
                mainSegment = segment
            } else {
                mainSegment = directSegment(from: mainStart, to: mainEnd, greatCircle: false, speed: mainSpeed)
            }
        case .airport:
            mainSegment = directSegment(from: mainStart, to: mainEnd, greatCircle: true, speed: mainSpeed)
        case .port:
            mainSegment = directSegment(from: mainStart, to: mainEnd, greatCircle: false, speed: mainSpeed)
        }
        segments.append((leg: (title: mainMode.title, image: mainMode.systemImage), segment: mainSegment))

        // 3. Finir le trajet jusqu'à la destination.
        if let endHub {
            hubs.append(endHub)
            if straightDistance(endHub.coordinate, end) > TransportHubKind.alreadyThereDistance {
                try Task.checkCancellation()
                let segment = try await roadSegment(from: endHub.coordinate, to: end, transportType: access.transportType, fixedSpeed: access.fixedSpeed)
                segments.append((leg: (title: access.title, image: access.systemImage), segment: segment))
            }
        }
    }

    // Assemble les étapes en un seul trajet, chacune à sa propre vitesse.
    var displayCoordinates: [CLLocationCoordinate2D] = []
    var samples: [RoutePlaybackSample] = []
    var legs: [JourneyLeg] = []
    var totalDistance: CLLocationDistance = 0
    var totalDuration: TimeInterval = 0
    for (leg, segment) in segments {
        guard !segment.coordinates.isEmpty else { continue }
        // On relie chaque étape à la fin de la précédente pour éviter tout saut de position.
        let path = (displayCoordinates.last.map { [$0] } ?? []) + segment.coordinates
        let legSamples = buildPlaybackSamples(from: path, speedWays: [], fallbackSpeedMetersPerSecond: segment.speed)
        samples.append(contentsOf: samples.isEmpty ? legSamples : Array(legSamples.dropFirst()))
        displayCoordinates.append(contentsOf: segment.coordinates)
        let duration = segment.distance / max(segment.speed, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        legs.append(JourneyLeg(title: leg.title, systemImage: leg.image, duration: duration))
        totalDistance += segment.distance
        totalDuration += duration
    }
    guard displayCoordinates.count > 1 else {
        throw NSError(domain: "RouteSimulation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aucun itinéraire trouvé."])
    }

    return JourneyPlan(
        displayCoordinates: displayCoordinates,
        samples: samples,
        distance: totalDistance,
        duration: totalDuration,
        legs: legs,
        hubs: hubs,
        notes: notes
    )
}

private struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

/// Trajet d'avion : suit l'arc de grand cercle, comme une vraie route aérienne,
/// au lieu d'une ligne droite sur la carte.
private func greatCircleCoordinates(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    pointCount: Int
) -> [CLLocationCoordinate2D] {
    let lat1 = start.latitude * .pi / 180
    let lon1 = start.longitude * .pi / 180
    let lat2 = end.latitude * .pi / 180
    let lon2 = end.longitude * .pi / 180

    let haversine = pow(sin((lat2 - lat1) / 2), 2) + cos(lat1) * cos(lat2) * pow(sin((lon2 - lon1) / 2), 2)
    let angle = 2 * asin(min(1, sqrt(haversine)))
    let steps = max(1, pointCount)
    // Points confondus ou diamétralement opposés : l'arc n'est pas défini, on garde la ligne droite.
    guard angle > 1e-9, sin(angle) > 1e-9 else { return [start, end] }

    var coordinates: [CLLocationCoordinate2D] = []
    coordinates.reserveCapacity(steps + 1)
    for index in 0...steps {
        let fraction = Double(index) / Double(steps)
        let a = sin((1 - fraction) * angle) / sin(angle)
        let b = sin(fraction * angle) / sin(angle)
        let x = a * cos(lat1) * cos(lon1) + b * cos(lat2) * cos(lon2)
        let y = a * cos(lat1) * sin(lon1) + b * cos(lat2) * sin(lon2)
        let z = a * sin(lat1) + b * sin(lat2)
        coordinates.append(
            CLLocationCoordinate2D(
                latitude: atan2(z, sqrt(x * x + y * y)) * 180 / .pi,
                longitude: atan2(y, x) * 180 / .pi
            )
        )
    }
    return coordinates
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

private func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D],
    speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let firstCoordinate = displayCoordinates.first else { return [] }

    var samples = [RoutePlaybackSample(coordinate: firstCoordinate, delayFromPrevious: 0)]

    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speedLimit = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays) ?? fallbackSpeedMetersPerSecond
        let clampedSpeed = max(speedLimit, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        let segmentTravelTime = segmentDistance / clampedSpeed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / RouteSimulationDefaults.playbackTickInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
            }
        }
    }

    return samples
}

private func fixedSpeedPlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    speedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: [],
        fallbackSpeedMetersPerSecond: speedMetersPerSecond
    )
}

private func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    // Sur un long trajet, la vitesse moyenne de l'itinéraire suffit et évite une attente interminable.
    let isShortRoute = distanceAlong(displayCoordinates) <= RouteSimulationDefaults.speedLimitLookupMaxDistance
    let speedWays = isShortRoute ? ((try? await fetchOpenStreetMapWays(for: displayCoordinates)) ?? []) : []
    return buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: speedWays,
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Le fichier choisi est vide."
        case .noCoordinates:
            return "Aucune coordonnée valide trouvée. Utilise un fichier GPX, GeoJSON, JSON, CSV ou texte avec latitudes et longitudes."
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LocationSimulationView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var showConnectedStatus = true
    @State private var locationConnectionNotice: String?
    @State private var connectionErrorMessage: String?
    private var isDeviceConnected: Bool {
        tunnel.isConnected && !tunnel.isStarting && tunnel.lastError == nil && connectionErrorMessage == nil
    }
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var autoReturnTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @AppStorage("travelMode") private var travelModeRaw = TravelMode.car.rawValue
    @AppStorage("customSpeedKmh") private var customSpeedKmh = 50.0
    /// Trajet complet (train, avion, bateau) : passer par la gare, l'aéroport ou le port.
    @AppStorage("useTransportHubs") private var useTransportHubs = true
    @AppStorage("accessMode") private var accessModeRaw = AccessMode.car.rawValue
    private var accessMode: AccessMode {
        AccessMode(rawValue: accessModeRaw) ?? .car
    }
    @State private var journeyLegs: [JourneyLeg] = []
    @State private var journeyHubs: [TransportHub] = []
    @State private var journeyNotes: [String] = []
    private var travelMode: TravelMode {
        TravelMode(rawValue: travelModeRaw) ?? .car
    }
    @State private var showCustomSpeedPrompt = false
    @State private var customSpeedInput = ""
    /// Le curseur couvre les vitesses courantes ; une vitesse plus haute se tape à la main.
    private var customSpeedSliderBinding: Binding<Double> {
        Binding(
            get: { min(max(customSpeedKmh, 1), RouteSimulationDefaults.customSpeedSliderMaxKmh) },
            set: { customSpeedKmh = $0 }
        )
    }
    @State private var showCoordinateImporter = false
    @State private var showRouteSearch = false
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulationSession.isActive || simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil || simulationSession.routeCoordinates != nil
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil ||
        simulationSession.routeCoordinates != nil
    }

    private var displayedRouteCoordinate: CLLocationCoordinate2D? {
        simulationSession.routeCoordinates == nil ? routePlaybackCoordinate : simulationSession.coordinate
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let durationText = Self.routeDurationFormatter.string(from: routePlan.expectedTravelTime)
        let speedText = travelMode.speedHint(customKmh: customSpeedKmh)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • \(durationText) • \(speedText)"
        }
        return "\(distanceText) • \(speedText)"
    }

    private var routeStatusText: String {
        if simulationSession.routeCoordinates != nil {
            return "Trajet en cours."
        }
        if isLoadingRoute {
            return "Calcul du trajet…"
        }
        if isPrefetchingRouteSpeeds {
            return "Préparation du trajet…"
        }
        if routePlan != nil {
            return "Trajet prêt."
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "Choisis un départ et une arrivée."
        }
        return "Crée un trajet avec le bouton en haut."
    }

    private var routeAttributionLink: some View {
        Link(
            "Vitesses de route © contributeurs OpenStreetMap (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(8), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    if hasRouteContext {
                        if let routePolyline {
                            MapPolyline(routePolyline)
                                .stroke(.blue.opacity(0.8), lineWidth: 5)
                        }
                        if let routeStartCoordinate {
                            Marker("Départ", coordinate: routeStartCoordinate)
                                .tint(.green)
                        }
                        if let routeEndCoordinate {
                            Marker("Arrivée", coordinate: routeEndCoordinate)
                                .tint(.red)
                        }
                        ForEach(Array(journeyHubs.enumerated()), id: \.offset) { _, hub in
                            Marker(hub.name, systemImage: hub.systemImage, coordinate: hub.coordinate)
                                .tint(.orange)
                        }
                        if let displayedRouteCoordinate {
                            Marker("Toi", coordinate: displayedRouteCoordinate)
                                .tint(.blue)
                        }
                    } else if let coordinate {
                        Marker(
                            hasActiveSimulation ? "Tu es ici" : "Lieu choisi",
                            systemImage: hasActiveSimulation ? "location.fill" : "mappin",
                            coordinate: coordinate
                        )
                        .tint(hasActiveSimulation ? Color.accentColor : .red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let loc = proxy.convert(point, from: .local) {
                        applySelection(loc)
                    }
                }
                .mapControls {
                    MapCompass()
                }
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        withAnimation(.easeInOut(duration: 0.9)) {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                        }
                    }
                }

            VStack(spacing: 0) {
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if isImportingCoordinates {
                        ProgressView("Import des coordonnées…")
                            .font(.footnote)
                    }

                    if hasRouteContext {
                        routeControls
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        pinControls
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(16)
                .frame(maxWidth: 520)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .padding(.bottom, 16)
                .padding(.horizontal, 14)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasRouteContext)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: coordinate.map(CoordinateSnapshot.init))
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasActiveSimulation)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: travelModeRaw)
                .sensoryFeedback(.success, trigger: hasActiveSimulation) { _, active in active }
                .sensoryFeedback(.impact(weight: .light), trigger: hasActiveSimulation) { _, active in !active }
                .sensoryFeedback(.selection, trigger: coordinate.map(CoordinateSnapshot.init))
                .sensoryFeedback(.selection, trigger: travelModeRaw)
                .sensoryFeedback(.error, trigger: showAlert) { _, shown in shown }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
            TrialBadge()
            if locationConnectionNotice != nil || !isDeviceConnected || showConnectedStatus || tunnel.connectionNotice != nil {
                Group {
                    if let notice = locationConnectionNotice {
                        Label(notice, systemImage: "airplane")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        DeviceConnectionStatusView(errorMessage: connectionErrorMessage)
                    }
                }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
            }
        }
            }
        .task(id: isDeviceConnected) {
            showConnectedStatus = true
            guard isDeviceConnected else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                showConnectedStatus = false
            } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationTunnelConnected).receive(on: DispatchQueue.main)) { notification in
            locationConnectionNotice = notification.object as? String
        }
        .task(id: locationConnectionNotice) {
            guard locationConnectionNotice != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            locationConnectionNotice = nil
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "list.star")
                }

                Button {
                    showRouteSearch = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(isBusy || isRouteRunning)

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("Importer des coordonnées")
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("Ville, adresse, lieu…", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
                    .onSubmit {
                        applyCoordinatesFromSearchText()
                    }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Vitesse du trajet", isPresented: $showCustomSpeedPrompt) {
            TextField("km/h", text: $customSpeedInput)
                .keyboardType(.numberPad)
            Button("Valider") { applyCustomSpeedInput() }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Entre la vitesse en km/h, de 1 à 2 000.")
        }
        .alert("Enregistrer ce lieu", isPresented: $showSaveBookmark) {
            TextField("Nom", text: $newBookmarkName)
            Button("Enregistrer") { addBookmark() }
            Button("Annuler", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Donne un nom à ce lieu.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onSelectDestination: { coordinate in
                applySelection(coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection
            ) { startSelection, endSelection in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                refreshRoute()
            }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .onAppear {
            loadBookmarks()
            if let routeCoordinates = simulationSession.routeCoordinates {
                coordinate = nil
                routePolyline = makeRoutePolyline(for: routeCoordinates)
                routeStartSelection = routeCoordinates.first.map {
                    RouteSearchSelection(title: "Départ", coordinate: $0)
                }
                routeEndSelection = routeCoordinates.last.map {
                    RouteSearchSelection(title: "Arrivée", coordinate: $0)
                }
                if let routePolyline {
                    position = .rect(routePolyline.boundingMapRect)
                }
            } else if let activeCoordinate = simulationSession.coordinate {
                coordinate = activeCoordinate
                simulatedCoordinate = activeCoordinate
            }
        }
        .onDisappear {
            locationConnectionNotice = nil
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            routeSpeedPrefetchTask = nil
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func applyCustomSpeedInput() {
        let digits = customSpeedInput.filter(\.isNumber)
        guard let value = Double(digits) else { return }
        let range = RouteSimulationDefaults.customSpeedRangeKmh
        customSpeedKmh = min(max(value, range.lowerBound), range.upperBound)
        refreshRoute()
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        if plan == nil {
            journeyLegs = []
            journeyHubs = []
            journeyNotes = []
        }
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                if let item = response?.mapItems.first {
                    applySelection(item.placemark.coordinate)
                }
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard importedCoordinates.isEmpty else {
            searchText = ""
            searchCompleter.results = []
            applyImportedCoordinates(importedCoordinates, sourceName: "Import")
            return
        }

        // Du texte et non des coordonnées : on prend la première suggestion, sinon on cherche le lieu tapé.
        if let firstResult = searchCompleter.results.first {
            selectSearchResult(firstResult)
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                guard let item = response?.mapItems.first else {
                    alertTitle = "Lieu introuvable"
                    alertMessage = "Aucun lieu trouvé pour « \(query) ». Vérifie l'orthographe ou ajoute la ville."
                    showAlert = true
                    return
                }
                searchText = ""
                searchCompleter.results = []
                applySelection(item.placemark.coordinate)
            }
        }
    }

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "Import" : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate)
            return
        }

        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            applySelection(firstCoordinate)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = RouteSimulationDefaults.importedRouteFallbackSpeedMetersPerSecond
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) : départ", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) : arrivée", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        let requestID = UUID()
        routeRequestID = requestID
        isPrefetchingRouteSpeeds = true
        routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            let playbackSamples = await prefetchRoutePlaybackSamples(
                displayCoordinates: displayCoordinates,
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard routeRequestID == requestID else { return }
                routePlaybackSamples = playbackSamples
                isPrefetchingRouteSpeeds = false
            }
        }
    }

    private func showImportError(_ error: Error) {
        alertTitle = "Import impossible"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(hasActiveSimulation ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 9, height: 9)
                            .symbolEffect(.pulse, isActive: hasActiveSimulation)
                        Text(hasActiveSimulation ? "Position changée" : "Lieu choisi")
                            .font(.headline)
                            .contentTransition(.opacity)
                    }
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 42, height: 42)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.primary)
                .disabled(isRouteRunning)
                .accessibilityLabel("Enregistrer ce lieu")
            }

            Button(action: simulate) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "location.fill")
                    }
                    Text(hasActiveSimulation ? "Me déplacer ici" : "Changer ma position ici")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!pairingExists || isBusy || isLoadingRoute)
            .opacity(!pairingExists ? 0.5 : 1)

            if hasActiveSimulation {
                Button(action: clear) {
                    Label("Retour à ma vraie position", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.red)
                .disabled(!pairingExists || isBusy)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse)
                Text("Choisis où tu veux être")
                    .font(.headline)
                Text("Touche la carte, cherche une adresse ou ouvre les destinations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            if hasActiveSimulation {
                Button(action: clear) {
                    Label("Retour à ma vraie position", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.red)
                .disabled(!pairingExists || isBusy)
            }
        }
    }

    private func legDurationText(_ duration: TimeInterval) -> String {
        guard duration >= 60 else { return "< 1 min" }
        return Self.routeDurationFormatter.string(from: duration) ?? ""
    }

    /// « Voiture 12 min → Train 2 h → À pied 8 min », puis les remarques éventuelles.
    private var journeySummary: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(journeyLegs.enumerated()), id: \.element.id) { index, leg in
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        Label("\(leg.title) \(legDurationText(leg.duration))", systemImage: leg.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
            }
            ForEach(journeyNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// Réglages du trajet complet : passer par la gare (ou l'aéroport, le port) et comment la rejoindre.
    @ViewBuilder
    private var journeyOptions: some View {
        if let hubKind = travelMode.hubKind {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $useTransportHubs) {
                    Label("Passer par \(hubKind.article)", systemImage: hubKind.systemImage)
                        .font(.footnote.weight(.semibold))
                }
                .onChange(of: useTransportHubs) { _, _ in
                    refreshRoute()
                }
                if useTransportHubs {
                    Text("Pour rejoindre \(hubKind.article) et en repartir :")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Pour rejoindre \(hubKind.article)", selection: $accessModeRaw) {
                        ForEach(AccessMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: accessModeRaw) { _, _ in
                        refreshRoute()
                    }
                }
            }
            .disabled(isBusy || isRouteRunning)
            .opacity(isRouteRunning ? 0.55 : 1)
        }
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !isLoadingRoute && !journeyLegs.isEmpty {
                journeySummary
            }

            routeAttributionLink

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TravelMode.allCases) { mode in
                        let selected = mode.rawValue == travelModeRaw
                        Button {
                            travelModeRaw = mode.rawValue
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(.body.weight(.semibold))
                                    .frame(height: 20)
                                Text(mode.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .frame(minWidth: 68, minHeight: 54)
                            .padding(.horizontal, 4)
                            .background(
                                selected ? Color.accentColor : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(mode.title)
                    }
                }
            }
            .disabled(isBusy || isRouteRunning)
            .opacity(isRouteRunning ? 0.55 : 1)
            .onChange(of: travelModeRaw) { _, _ in
                refreshRoute()
            }

            journeyOptions

            if travelMode == .custom {
                HStack(spacing: 10) {
                    Slider(value: customSpeedSliderBinding, in: 1...RouteSimulationDefaults.customSpeedSliderMaxKmh, step: 1) { editing in
                        if !editing {
                            refreshRoute()
                        }
                    }
                    // Touche la vitesse pour taper la valeur exacte (jusqu'à 2 000 km/h).
                    Button {
                        customSpeedInput = String(Int(customSpeedKmh))
                        showCustomSpeedPrompt = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(Int(customSpeedKmh)) km/h")
                                .font(.footnote.monospaced().weight(.semibold))
                                .contentTransition(.numericText())
                            Image(systemName: "pencil")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Saisir la vitesse")
                }
                .disabled(isBusy || isRouteRunning)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button(action: simulateRoute) {
                HStack(spacing: 8) {
                    if isBusy || isLoadingRoute || isPrefetchingRouteSpeeds {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: isRouteRunning ? "location.north.line.fill" : "play.fill")
                    }
                    Text(isRouteRunning ? "Trajet en cours" : "Lancer le trajet")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(
                !pairingExists ||
                isBusy ||
                isRouteRunning ||
                isLoadingRoute ||
                isPrefetchingRouteSpeeds ||
                routePlan == nil ||
                routePlaybackSamples.isEmpty
            )

            HStack(spacing: 10) {
                Button(action: clear) {
                    Label("Retour réel", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.red)
                .disabled(!pairingExists || isBusy || !hasActiveSimulation)
                .opacity(hasActiveSimulation ? 1 : 0.45)

                Button(action: resetRouteSelection) {
                    Label("Effacer", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(.primary)
                .disabled(isBusy || isRouteRunning)
                .opacity(isRouteRunning ? 0.45 : 1)
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        runLocationCommand(
            errorTitle: "Changement impossible",
            errorMessage: { code in
                "Impossible de changer la position (erreur \(code)). Vérifie que LocalDevVPN est activé, puis utilise « Réparer la connexion » dans Réglages."
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            LocationSimulationSession.shared.clearRoute()
            startResendLoop(with: coord)
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              let routePlan,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy else {
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "Trajet impossible",
            errorMessage: { code in
                "Impossible de lancer le trajet (erreur \(code)). Vérifie que LocalDevVPN est activé, puis utilise « Réparer la connexion » dans Réglages."
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(
                at: firstCoordinate,
                coordinates: routePlan.displayCoordinates
            )
            simulatedCoordinate = nil
            routePlaybackCoordinate = firstCoordinate
            startRoutePlayback(routeID: routeID)
        }
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    connectionErrorMessage = nil
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    connectionErrorMessage = "Code \(code): \(alertMessage)"
                    locationConnectionNotice = nil
                    showAlert = true
                }
            }
        }
    }

    private func clear() {
        guard pairingExists, !isBusy else { return }
        autoReturnTask?.cancel()
        autoReturnTask = nil
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        LocationSimulationSession.shared.clearRoute()
        runLocationCommand(
            errorTitle: "Retour impossible",
            errorMessage: { code in "Impossible de revenir à la vraie position (erreur \(code)). Redémarre l'iPhone pour la retrouver." },
            operation: clear_simulated_location
        ) {
            endBackgroundTask()
            LocationSimulationSession.shared.stop()
            locationConnectionNotice = nil
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        LocationSimulationSession.shared.startResending(at: coordinate) {
            // Micro-mouvements : la position bouge de quelques mètres, comme un vrai téléphone posé.
            let target = UserDefaults.standard.bool(forKey: "microMovements")
                ? jitteredCoordinate(around: coordinate)
                : coordinate
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: target)
            }
        }
        scheduleAutoReturn()
    }

    private func jitteredCoordinate(around coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let meters = 3.0
        let latitudeOffset = Double.random(in: -meters...meters) / 111_111
        let longitudeScale = max(cos(coordinate.latitude * .pi / 180), 0.01)
        let longitudeOffset = Double.random(in: -meters...meters) / (111_111 * longitudeScale)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeOffset,
            longitude: coordinate.longitude + longitudeOffset
        )
    }

    // Retour automatique : la vraie position revient seule après la durée choisie dans Réglages.
    private func scheduleAutoReturn() {
        autoReturnTask?.cancel()
        autoReturnTask = nil
        let minutes = UserDefaults.standard.integer(forKey: "autoReturnMinutes")
        guard minutes > 0 else { return }
        autoReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            autoReturnTask = nil
            clear()
        }
    }

    private func stopResendLoop() {
        LocationSimulationSession.shared.pauseResending()
        simulatedCoordinate = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        self.coordinate = coordinate
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
    }

    private func refreshRoute() {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        setRoutePlan(nil)
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        let mode = travelMode
        let fixedSpeed = mode.fixedSpeed(customKmh: customSpeedKmh)

        if useTransportHubs, let hubKind = mode.hubKind {
            isLoadingRoute = true
            isPrefetchingRouteSpeeds = false
            let access = accessMode
            routeLoadTask = Task {
                do {
                    let plan = try await buildJourneyPlan(
                        from: routeStart,
                        to: routeEnd,
                        mainMode: mode,
                        kind: hubKind,
                        access: access
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard routeRequestID == requestID else { return }
                        setRoutePlan(
                            RouteSimulationPlan(
                                displayCoordinates: plan.displayCoordinates,
                                distance: plan.distance,
                                expectedTravelTime: plan.duration
                            )
                        )
                        routePlaybackSamples = plan.samples
                        journeyLegs = plan.legs
                        journeyHubs = plan.hubs
                        journeyNotes = plan.notes
                        isLoadingRoute = false
                        isPrefetchingRouteSpeeds = false
                        if let routePolyline {
                            position = .rect(routePolyline.boundingMapRect)
                        }
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        guard routeRequestID == requestID else { return }
                        isLoadingRoute = false
                        isPrefetchingRouteSpeeds = false
                    }
                } catch {
                    await MainActor.run {
                        guard routeRequestID == requestID else { return }
                        isLoadingRoute = false
                        isPrefetchingRouteSpeeds = false
                        alertTitle = "Trajet impossible"
                        alertMessage = "Le trajet complet n'a pas pu être calculé. Vérifie ta connexion, ou désactive « Passer par \(hubKind.article) » pour un trajet direct."
                        showAlert = true
                    }
                }
            }
            return
        }

        if !mode.followsRoads {
            // Bateau et avion : ligne droite entre le départ et l'arrivée.
            let speed = fixedSpeed ?? 13.4
            let distance = CLLocation(latitude: routeStart.latitude, longitude: routeStart.longitude)
                .distance(from: CLLocation(latitude: routeEnd.latitude, longitude: routeEnd.longitude))
            let spacing = max(RouteSimulationDefaults.pathSamplingDistance, distance / 2000)
            let displayCoordinates: [CLLocationCoordinate2D]
            if mode == .plane {
                displayCoordinates = greatCircleCoordinates(
                    from: routeStart,
                    to: routeEnd,
                    pointCount: Int(ceil(distance / spacing))
                )
            } else {
                displayCoordinates = sampledRouteCoordinates(from: [routeStart, routeEnd], targetDistance: spacing)
            }
            setRoutePlan(
                RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: distance,
                    expectedTravelTime: distance / speed
                )
            )
            routePlaybackSamples = buildPlaybackSamples(
                from: displayCoordinates,
                speedWays: [],
                fallbackSpeedMetersPerSecond: speed
            )
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            if let routePolyline {
                position = .rect(routePolyline.boundingMapRect)
            }
            return
        }

        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false

        func directionsRequest(_ transportType: MKDirectionsTransportType) -> MKDirections.Request {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
            request.requestsAlternateRoutes = false
            request.transportType = transportType
            return request
        }

        routeLoadTask = Task {
            do {
                let response: MKDirections.Response
                do {
                    response = try await MKDirections(request: directionsRequest(mode.transportType)).calculate()
                } catch {
                    // Plans ne propose pas d'itinéraire piéton sur les très longues distances :
                    // on suit alors les routes, toujours à la vitesse du mode choisi.
                    guard mode.transportType == .walking, !Task.isCancelled else { throw error }
                    response = try await MKDirections(request: directionsRequest(.automobile)).calculate()
                }
                guard !Task.isCancelled else { return }
                guard let route = response.routes.first else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Aucun itinéraire trouvé entre ces deux points."]
                    )
                }

                let displayCoordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: max(
                        RouteSimulationDefaults.pathSamplingDistance,
                        route.distance / RouteSimulationDefaults.maximumDisplayPointCount
                    )
                )
                let routePlan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: route.distance,
                    expectedTravelTime: fixedSpeed.map { route.distance / $0 } ?? route.expectedTravelTime
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    self.setRoutePlan(routePlan)
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = true
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                }

                let fallbackSpeed = route.expectedTravelTime > 0
                    ? route.distance / route.expectedTravelTime
                    : 13.4

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    routeSpeedPrefetchTask?.cancel()
                    routeSpeedPrefetchTask = Task.detached(priority: .utility) {
                        let playbackSamples: [RoutePlaybackSample]
                        if let fixedSpeed {
                            playbackSamples = await fixedSpeedPlaybackSamples(
                                displayCoordinates: displayCoordinates,
                                speedMetersPerSecond: fixedSpeed
                            )
                        } else {
                            playbackSamples = await prefetchRoutePlaybackSamples(
                                displayCoordinates: displayCoordinates,
                                fallbackSpeedMetersPerSecond: fallbackSpeed
                            )
                        }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routePlaybackSamples = playbackSamples
                            isPrefetchingRouteSpeeds = false
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "Trajet impossible"
                    alertMessage = "Aucun itinéraire trouvé entre ces deux lieux. Essaie un autre mode (avion ou bateau pour traverser la mer) ou d'autres adresses."
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback(routeID: UUID) {
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate = routePlaybackSamples.first?.coordinate

            for sample in routePlaybackSamples.dropFirst() {
                try? await Task.sleep(for: .seconds(sample.delayFromPrevious))
                guard !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    return
                }

                let code = await sendLocationUpdate(for: sample.coordinate)
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                guard code == 0 else {
                    await MainActor.run {
                        routePlaybackTask = nil
                        routePlaybackCoordinate = lastSuccessfulCoordinate
                        LocationSimulationSession.shared.clearRoute()
                        if let lastSuccessfulCoordinate {
                            startResendLoop(with: lastSuccessfulCoordinate)
                        }
                        alertTitle = "Trajet interrompu"
                        alertMessage = "Le trajet s'est arrêté (erreur \(code))."
                        connectionErrorMessage = "Code \(code) : le trajet s'est arrêté."
                        locationConnectionNotice = nil
                        showAlert = true
                    }
                    return
                }

                lastSuccessfulCoordinate = sample.coordinate
                await MainActor.run {
                    routePlaybackCoordinate = sample.coordinate
                    LocationSimulationSession.shared.updateCoordinate(sample.coordinate)
                }
            }

            await MainActor.run {
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                routePlaybackTask = nil
                // The route has ended; while it stays set, isRouteRunning keeps
                // map taps, search, bookmarks and Reset disabled.
                LocationSimulationSession.shared.clearRoute()
                if let lastSuccessfulCoordinate {
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                }
            }
        }
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: RouteSearchSelection?
    let initialEnd: RouteSearchSelection?
    let onApply: (RouteSearchSelection, RouteSearchSelection) -> Void

    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: RouteSearchField?
    /// Dernier champ modifié : sert si le clavier est fermé au moment où l'on touche une suggestion.
    @State private var lastEditedField: RouteSearchField = .start

    init(
        initialStart: RouteSearchSelection?,
        initialEnd: RouteSearchSelection?,
        onApply: @escaping (RouteSearchSelection, RouteSearchSelection) -> Void
    ) {
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onApply = onApply
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        // Clavier fermé : on garde les suggestions du dernier champ modifié tant qu'il n'a pas de lieu choisi.
        switch focusedField ?? lastEditedField {
        case .start:
            return startSelection == nil ? startCompleter.results : []
        case .end:
            return endSelection == nil ? endCompleter.results : []
        }
    }

    /// « Utiliser » fonctionne dès que les deux champs sont remplis :
    /// un lieu tapé sans toucher de suggestion est recherché automatiquement.
    private var canApply: Bool {
        let hasStart = startSelection != nil || !startQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasEnd = endSelection != nil || !endQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasStart && hasEnd && !isResolvingSelection
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                routeField(
                    title: "Départ",
                    icon: "circle.fill",
                    tint: .green,
                    text: $startQuery,
                    selection: startSelection,
                    field: .start
                )

                routeField(
                    title: "Arrivée",
                    icon: "flag.checkered.circle.fill",
                    tint: .red,
                    text: $endQuery,
                    selection: endSelection,
                    field: .end
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isResolvingSelection {
                    ProgressView("Recherche du lieu…")
                        .font(.footnote)
                } else if !activeResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(activeResults.enumerated()), id: \.element) { index, result in
                                Button {
                                    resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)

                                if index < activeResults.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("Tape un départ et une arrivée, puis touche « Utiliser ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Nouveau trajet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Utiliser") {
                        applyRoute()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canApply)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if startSelection == nil {
                focusedField = .start
            } else if endSelection == nil {
                focusedField = .end
            }
        }
    }

    private func routeField(
        title: String,
        icon: String,
        tint: Color,
        text: Binding<String>,
        selection: RouteSearchSelection?,
        field: RouteSearchField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                TextField(title, text: text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        errorMessage = nil
                        update(query: newValue, for: field)
                    }
                    .onSubmit {
                        if field == .start {
                            focusedField = .end
                        } else {
                            // « Terminé » sur l'arrivée valide directement le trajet.
                            focusedField = nil
                            if canApply { applyRoute() }
                        }
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func update(query: String, for field: RouteSearchField) {
        if focusedField == field { lastEditedField = field }
        switch field {
        case .start:
            if query != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: query)
        case .end:
            if query != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: query)
        }
    }

    /// Valide le trajet. Les champs tapés à la main sont d'abord transformés en lieux.
    private func applyRoute() {
        guard !isResolvingSelection else { return }
        if let startSelection, let endSelection {
            onApply(startSelection, endSelection)
            dismiss()
            return
        }

        isResolvingSelection = true
        errorMessage = nil
        let typedStart = startQuery
        let typedEnd = endQuery
        let knownStart = startSelection
        let knownEnd = endSelection
        let startSuggestion = startCompleter.results.first
        let endSuggestion = endCompleter.results.first

        Task { @MainActor in
            let start: RouteSearchSelection?
            if let knownStart {
                start = knownStart
            } else {
                start = await Self.lookUp(typedStart, suggestion: startSuggestion)
            }
            let end: RouteSearchSelection?
            if let knownEnd {
                end = knownEnd
            } else {
                end = await Self.lookUp(typedEnd, suggestion: endSuggestion)
            }
            isResolvingSelection = false

            guard let start else {
                errorMessage = "Départ introuvable. Vérifie l'orthographe ou choisis une suggestion."
                focusedField = .start
                return
            }
            guard let end else {
                errorMessage = "Arrivée introuvable. Vérifie l'orthographe ou choisis une suggestion."
                focusedField = .end
                return
            }
            startSelection = start
            endSelection = end
            onApply(start, end)
            dismiss()
        }
    }

    /// Cherche un lieu à partir du texte tapé ; la première suggestion affichée passe en priorité.
    private static func lookUp(_ text: String, suggestion: MKLocalSearchCompletion?) async -> RouteSearchSelection? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        if let suggestion,
           let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start().mapItems.first {
            return RouteSearchSelection(title: query, coordinate: item.placemark.coordinate)
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return RouteSearchSelection(title: query, coordinate: item.placemark.coordinate)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? lastEditedField
        let request = MKLocalSearch.Request(completion: completion)
        isResolvingSelection = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isResolvingSelection = false

                guard let item = response?.mapItems.first else {
                    errorMessage = error?.localizedDescription ?? "Lieu introuvable."
                    return
                }

                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                let selection = RouteSearchSelection(title: title, coordinate: item.placemark.coordinate)

                switch field {
                case .start:
                    startSelection = selection
                    startQuery = title
                    startCompleter.results = []
                    focusedField = .end
                case .end:
                    endSelection = selection
                    endQuery = title
                    endCompleter.results = []
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

private struct Destination: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case all = "Tout"
        case city = "Villes"
        case beach = "Plages"
        case luxury = "Luxe"
        case landmark = "Lieux"

        var id: String { rawValue }
    }

    let flag: String
    let name: String
    let country: String
    let category: Category
    let latitude: Double
    let longitude: Double

    var id: String { name }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    static let all: [Destination] = [
        Destination(flag: "🇦🇪", name: "Dubaï, Burj Khalifa", country: "Émirats arabes unis", category: .landmark, latitude: 25.1972, longitude: 55.2744),
        Destination(flag: "🇦🇪", name: "Dubaï, Palm Jumeirah", country: "Émirats arabes unis", category: .luxury, latitude: 25.1304, longitude: 55.1171),
        Destination(flag: "🇫🇷", name: "Paris, tour Eiffel", country: "France", category: .landmark, latitude: 48.8584, longitude: 2.2945),
        Destination(flag: "🇫🇷", name: "Paris, Champs-Élysées", country: "France", category: .city, latitude: 48.8698, longitude: 2.3078),
        Destination(flag: "🇲🇨", name: "Monaco, casino de Monte-Carlo", country: "Monaco", category: .luxury, latitude: 43.7392, longitude: 7.4278),
        Destination(flag: "🇫🇷", name: "Saint-Tropez, le port", country: "France", category: .luxury, latitude: 43.2727, longitude: 6.6386),
        Destination(flag: "🇫🇷", name: "Cannes, la Croisette", country: "France", category: .beach, latitude: 43.5494, longitude: 7.0281),
        Destination(flag: "🇫🇷", name: "Courchevel 1850", country: "France", category: .luxury, latitude: 45.4153, longitude: 6.6347),
        Destination(flag: "🇫🇷", name: "Marseille, Vieux-Port", country: "France", category: .city, latitude: 43.2951, longitude: 5.3744),
        Destination(flag: "🇫🇷", name: "Nice, promenade des Anglais", country: "France", category: .beach, latitude: 43.6950, longitude: 7.2650),
        Destination(flag: "🇺🇸", name: "New York, Times Square", country: "États-Unis", category: .city, latitude: 40.7580, longitude: -73.9855),
        Destination(flag: "🇺🇸", name: "Los Angeles, Beverly Hills", country: "États-Unis", category: .luxury, latitude: 34.0696, longitude: -118.4053),
        Destination(flag: "🇺🇸", name: "Miami Beach", country: "États-Unis", category: .beach, latitude: 25.7907, longitude: -80.1300),
        Destination(flag: "🇺🇸", name: "Las Vegas, le Strip", country: "États-Unis", category: .city, latitude: 36.1147, longitude: -115.1728),
        Destination(flag: "🇬🇧", name: "Londres, Big Ben", country: "Royaume-Uni", category: .landmark, latitude: 51.5007, longitude: -0.1246),
        Destination(flag: "🇪🇸", name: "Barcelone, Sagrada Família", country: "Espagne", category: .landmark, latitude: 41.4036, longitude: 2.1744),
        Destination(flag: "🇪🇸", name: "Ibiza, Playa d'en Bossa", country: "Espagne", category: .beach, latitude: 38.8850, longitude: 1.4070),
        Destination(flag: "🇪🇸", name: "Marbella, Puerto Banús", country: "Espagne", category: .luxury, latitude: 36.4870, longitude: -4.9520),
        Destination(flag: "🇮🇹", name: "Rome, le Colisée", country: "Italie", category: .landmark, latitude: 41.8902, longitude: 12.4922),
        Destination(flag: "🇮🇹", name: "Capri, Marina Grande", country: "Italie", category: .luxury, latitude: 40.5570, longitude: 14.2380),
        Destination(flag: "🇬🇷", name: "Mykonos", country: "Grèce", category: .beach, latitude: 37.4467, longitude: 25.3289),
        Destination(flag: "🇬🇷", name: "Santorin, Oia", country: "Grèce", category: .beach, latitude: 36.4618, longitude: 25.3753),
        Destination(flag: "🇲🇦", name: "Marrakech, Jemaa el-Fna", country: "Maroc", category: .city, latitude: 31.6258, longitude: -7.9891),
        Destination(flag: "🇹🇷", name: "Istanbul, Sainte-Sophie", country: "Turquie", category: .landmark, latitude: 41.0086, longitude: 28.9802),
        Destination(flag: "🇯🇵", name: "Tokyo, Shibuya", country: "Japon", category: .city, latitude: 35.6595, longitude: 139.7005),
        Destination(flag: "🇹🇭", name: "Phuket, Patong Beach", country: "Thaïlande", category: .beach, latitude: 7.8961, longitude: 98.2954),
        Destination(flag: "🇮🇩", name: "Bali, Canggu", country: "Indonésie", category: .beach, latitude: -8.6478, longitude: 115.1385),
        Destination(flag: "🇲🇻", name: "Maldives, Malé", country: "Maldives", category: .beach, latitude: 4.1755, longitude: 73.5093),
        Destination(flag: "🇧🇷", name: "Rio, Copacabana", country: "Brésil", category: .beach, latitude: -22.9711, longitude: -43.1822),
        Destination(flag: "🇦🇺", name: "Sydney, l'Opéra", country: "Australie", category: .landmark, latitude: -33.8568, longitude: 151.2153),
    ]
}

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onSelectDestination: (CLLocationCoordinate2D) -> Void
    let onDelete: (IndexSet) -> Void

    @State private var tab = 0
    @State private var category = Destination.Category.all
    @State private var filter = ""

    private var destinations: [Destination] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return Destination.all.filter { destination in
            (category == .all || destination.category == category)
                && (query.isEmpty
                    || destination.name.localizedCaseInsensitiveContains(query)
                    || destination.country.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Liste", selection: $tab) {
                    Text("Destinations").tag(0)
                    Text("Favoris").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if tab == 0 {
                    destinationList
                } else {
                    bookmarkList
                }
            }
            .navigationTitle(tab == 0 ? "Destinations" : "Favoris")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if tab == 1 && !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }

    private var destinationList: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Destination.Category.allCases) { item in
                            Button {
                                category = item
                            } label: {
                                Text(item.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(category == item ? Color.black : Color.primary)
                                    .background(
                                        category == item ? Color.accentColor : Color.secondary.opacity(0.18),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(destinations) { destination in
                    Button {
                        onSelectDestination(destination.coordinate)
                    } label: {
                        HStack(spacing: 12) {
                            Text(destination.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.name).foregroundStyle(.primary)
                                Text(destination.country).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if destinations.isEmpty {
                    Text("Aucune destination ne correspond.").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filtrer les destinations")
    }

    private var bookmarkList: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "Aucun favori",
                    systemImage: "bookmark.slash",
                    description: Text("Touche la carte puis l'icône de favori pour enregistrer un lieu.")
                )
            } else {
                List {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onSelect(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.name)
                                    .foregroundStyle(.primary)
                                Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: onDelete)
                }
            }
        }
    }
}
