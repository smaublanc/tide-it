//
//  PioupiouService.swift
//  Tide It
//
//  Intégration de l'API Pioupiou (https://api.pioupiou.fr) pour récupérer
//  le vent temps réel depuis le réseau communautaire d'anémomètres.
//
//  API publique gratuite, JSON, pas d'auth requise :
//    GET https://api.pioupiou.fr/v1/live-with-meta/all
//
//  Mise à jour des stations toutes les 2-5 min.
//  Licence CC-BY (crédit visible dans l'UI).
//
//  Scope actuel : fetch global + sélection de la station la plus proche
//  d'un port donné dans un rayon configurable.
//

import Foundation
import CoreLocation
import os.log

@MainActor
final class PioupiouService: ObservableObject {
    static let shared = PioupiouService()

    @Published private(set) var stations: [WindStation] = []
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 180  // 3 min

    private let endpoint = "https://api.pioupiou.fr/v1/live-with-meta/all"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public

    /// Rafraîchit la liste des stations si le cache est expiré (ou forceRefresh).
    func refreshIfNeeded(force: Bool = false) async {
        if !force,
           let last = lastFetch,
           Date().timeIntervalSince(last) < cacheTTL,
           !stations.isEmpty {
            return
        }

        do {
            let fetched = try await fetchAllStations()
            self.stations = fetched
            self.lastFetch = Date()
            appLogger.info("[Pioupiou] \(fetched.count) stations chargées")
        } catch {
            appLogger.warning("[Pioupiou] Erreur fetch: \(error.localizedDescription)")
        }
    }

    /// Rayon par défaut de recherche. Pioupiou est principalement un réseau
    /// parapente inland, donc on élargit à 25 km pour capturer plus de ports.
    /// `nonisolated` car constante immuable lue depuis des contextes non-MainActor
    /// (default arg de méthodes, accès depuis WindStationAggregator).
    nonisolated static let defaultSearchRadius: CLLocationDistance = 25_000

    /// Station la plus proche d'un point, dans un rayon max (mètres).
    /// Ne renvoie que les stations avec une mesure fraîche (< 30 min).
    func nearestStation(
        to coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> WindStation? {
        nearestStationWithDistance(to: coord, maxDistance: maxDistance)?.station
    }

    /// Variante qui renvoie la station ET la distance en mètres.
    func nearestStationWithDistance(
        to coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> (station: WindStation, distance: CLLocationDistance)? {
        stations
            .filter { $0.reading?.isFresh == true }
            .map { (station: $0, distance: $0.distance(to: coord)) }
            .filter { $0.distance <= maxDistance }
            .min { $0.distance < $1.distance }
    }

    /// Vrai si une station fraîche existe dans un rayon donné autour du port.
    /// Utilisé pour afficher le badge moulin à vent sur la carte.
    func hasNearbyStation(
        for port: Port,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> Bool {
        let coord = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
        return nearestStation(to: coord, maxDistance: maxDistance) != nil
    }

    // MARK: - Network

    private func fetchAllStations() async throws -> [WindStation] {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        // Decodage de ~700 stations HORS du main actor (evite un jank au demarrage a froid).
        let payload = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(PioupiouResponse.self, from: data)
        }.value

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoSimple = ISO8601DateFormatter()
        isoSimple.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoSimple.date(from: s)
        }

        return payload.data.compactMap { entry -> WindStation? in
            // Les coordonnées GPS sont dans `location`, pas dans `meta` !
            guard let lat = entry.location?.latitude,
                  let lon = entry.location?.longitude else { return nil }
            let name = entry.meta?.name ?? "Station \(entry.id)"

            // Optionnel : ignorer les stations off-line (status.state != "on")
            if let state = entry.status?.state, state != "on" { return nil }

            let reading: WindReading?
            if let m = entry.measurements,
               let measureDate = parseDate(m.date),
               let heading = m.wind_heading,
               let avg = m.wind_speed_avg {
                reading = WindReading(
                    date: measureDate,
                    speedAvgKmh: avg,
                    gustKmh: m.wind_speed_max,
                    minKmh: m.wind_speed_min,
                    directionDegrees: heading
                )
            } else {
                reading = nil
            }

            return WindStation(
                id: "pp_\(entry.id)",
                name: name,
                source: .pioupiou,
                latitude: lat,
                longitude: lon,
                reading: reading
            )
        }
    }

    // MARK: - Decodable

    private struct PioupiouResponse: Decodable {
        let data: [Entry]
    }

    private struct Entry: Decodable {
        let id: Int
        let meta: Meta?
        let location: Location?
        let measurements: Measurements?
        let status: Status?
    }

    private struct Meta: Decodable {
        let name: String?
        let description: String?
    }

    private struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        let date: String?
        let success: Bool?
    }

    private struct Measurements: Decodable {
        let date: String?
        let wind_heading: Double?
        let wind_speed_avg: Double?
        let wind_speed_max: Double?
        let wind_speed_min: Double?
    }

    private struct Status: Decodable {
        let state: String?
        let date: String?
    }
}
