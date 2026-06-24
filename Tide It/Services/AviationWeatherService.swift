//
//  AviationWeatherService.swift
//  Tide It
//
//  Source de vent temps réel basée sur les observations METAR des aéroports
//  via l'API publique d'aviationweather.gov (NOAA).
//
//  Sans auth, gratuit, couverture mondiale avec une densité élevée sur les
//  côtes (nombreux aéroports côtiers). Complémentaire de Pioupiou qui est
//  majoritairement inland pour le parapente.
//
//  Endpoint :
//    GET https://aviationweather.gov/api/data/metar?format=json&hours=2&bbox={minLat,minLon,maxLat,maxLon}
//
//  Mise à jour METAR : ~30 min par station (TAF/METAR régulières).
//  Vitesse de vent renvoyée en nœuds → converties en km/h (×1.852).
//

import Foundation
import CoreLocation
import os.log

@MainActor
final class AviationWeatherService: ObservableObject {
    static let shared = AviationWeatherService()

    @Published private(set) var stations: [WindStation] = []

    /// Cache par bbox (key = bbox signature rounded)
    private var lastBboxKey: String?
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 1200  // 20 min

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public

    /// Rafraîchit les stations METAR autour d'un point (bbox carré en degrés).
    /// Par défaut : ~3° autour (≈ 330 km N-S, ≈ 220 km E-O à 45° N).
    func refresh(
        around coord: CLLocationCoordinate2D,
        radiusDegrees: Double = 3.0,
        force: Bool = false
    ) async {
        // Bornage : un bbox simple `min,min,max,max` doit rester dans [-90,90]×[-180,180].
        // Pôles → on clampe la latitude. Antiméridien → on DÉCALE la fenêtre longitude pour
        // garder sa pleine largeur du côté valide (sinon Fiji/NZ/Aléoutiennes = 0 station METAR).
        let minLat = max(-90, coord.latitude - radiusDegrees)
        let maxLat = min(90, coord.latitude + radiusDegrees)
        var minLon = coord.longitude - radiusDegrees
        var maxLon = coord.longitude + radiusDegrees
        if maxLon > 180 { let w = maxLon - minLon; maxLon = 180; minLon = 180 - w }
        if minLon < -180 { let w = maxLon - minLon; minLon = -180; maxLon = -180 + w }
        let key = bboxKey(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)

        if !force,
           let last = lastFetch,
           Date().timeIntervalSince(last) < cacheTTL,
           lastBboxKey == key,
           !stations.isEmpty {
            return
        }

        do {
            let fetched = try await fetch(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            self.stations = fetched
            self.lastFetch = Date()
            self.lastBboxKey = key
            appLogger.info("[AviationWeather] \(fetched.count) stations METAR chargées")
        } catch {
            appLogger.warning("[AviationWeather] Erreur fetch : \(error.localizedDescription)")
        }
    }

    // MARK: - Network

    private func fetch(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async throws -> [WindStation] {
        let bboxString = "\(minLat),\(minLon),\(maxLat),\(maxLon)"
        guard var components = URLComponents(string: "https://aviationweather.gov/api/data/metar") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "hours", value: "2"),
            URLQueryItem(name: "bbox", value: bboxString)
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode([MetarEntry].self, from: data)
        return decoded.compactMap { entry -> WindStation? in
            guard let lat = entry.lat, let lon = entry.lon else { return nil }
            // wspd peut être Int (nœuds) ou null ; wdir peut être "VRB" (variable) → on ignore
            guard let wspdKt = entry.wspd?.doubleValue, wspdKt >= 0 else { return nil }
            guard let heading = entry.wdir?.degreesValue else { return nil }

            let reading = WindReading(
                date: Date(timeIntervalSince1970: TimeInterval(entry.obsTime ?? Int(Date().timeIntervalSince1970))),
                speedAvgKmh: wspdKt * 1.852,
                gustKmh: entry.wgst?.doubleValue.map { $0 * 1.852 },
                minKmh: nil,
                directionDegrees: heading
            )

            let displayName = formattedStationName(entry)
            return WindStation(
                id: "metar_\(entry.icaoId ?? UUID().uuidString)",
                name: displayName,
                source: .metar,
                latitude: lat,
                longitude: lon,
                reading: reading
            )
        }
    }

    private func formattedStationName(_ entry: MetarEntry) -> String {
        let raw = entry.name ?? entry.icaoId ?? "METAR"
        // "Brest/Guipavas Arpt, BR, FR" → "Brest/Guipavas"
        if let short = raw.split(separator: ",").first.map(String.init) {
            return short.replacingOccurrences(of: " Arpt", with: "").trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    private func bboxKey(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> String {
        String(format: "%.1f_%.1f_%.1f_%.1f", minLat, minLon, maxLat, maxLon)
    }

    // MARK: - Decodable

    private struct MetarEntry: Decodable {
        let icaoId: String?
        let name: String?
        let lat: Double?
        let lon: Double?
        let obsTime: Int?
        let wspd: IntOrString?
        let wgst: IntOrString?
        let wdir: IntOrString?
    }

    /// L'API AviationWeather renvoie parfois les valeurs en Int, parfois en String ("VRB" pour wdir variable)
    private enum IntOrString: Decodable {
        case int(Int)
        case string(String)
        case null

        var doubleValue: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .string(let s): return Double(s)
            case .null: return nil
            }
        }

        /// Retourne les degrés si c'est numérique, ou 0 si "VRB" (variable), ou nil si absent
        var degreesValue: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .string(let s):
                if s.uppercased() == "VRB" { return 0 }  // variable : on affiche Nord par défaut
                return Double(s)
            case .null: return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
                return
            }
            if let i = try? container.decode(Int.self) {
                self = .int(i)
                return
            }
            if let s = try? container.decode(String.self) {
                self = .string(s)
                return
            }
            self = .null
        }
    }
}
