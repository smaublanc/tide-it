//
//  WatchWindService.swift
//  Tide Watch Watch App
//
//  Fetch DIRECT (sans iPhone) de la balise vent réelle la plus proche, via winds.mobi
//  (requête géo keyless, réponse légère). watchOS fait tourner URLSession indépendamment
//  sur WiFi (toute Watch) et cellular (modèles cellular) → c'est le fix « vent à la plage
//  sans téléphone ». 100 % DÉFENSIF : toute erreur (réseau, décodage, aucune balise) laisse
//  l'état inchangé → la pastille garde le vent fourni par le téléphone. Aucune clé en dur.
//

import Foundation
import Combine
import CoreLocation
import os.log

private let windLogger = Logger(subsystem: "seb.Tide-It.watchkitapp", category: "WatchWind")

@MainActor
final class WatchWindService: ObservableObject {
    static let shared = WatchWindService()

    /// Dernière balise fraîche trouvée pour la coord demandée (nil tant qu'on n'a rien).
    @Published private(set) var speedKmh: Double?
    @Published private(set) var gustKmh: Double?
    @Published private(set) var directionDeg: Double?
    @Published private(set) var stationName: String?
    @Published private(set) var date: Date?

    private var lastFetch: Date = .distantPast
    private var lastCoordKey: String = ""
    private let cacheTTL: TimeInterval = 180        // 3 min : on ne re-fetch pas plus souvent
    private let maxAgeSeconds: TimeInterval = 60 * 60   // mesure < 60 min (cohérent app/pastille)
    private let maxAltitudeMeters = 120             // exclut les balises montagne / parapente

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.waitsForConnectivity = false              // échoue vite si pas de réseau (cas plage)
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Récupère la balise vent FRAÎCHE la plus proche de (lat, lon). Throttlé + non bloquant.
    func refresh(lat: Double, lon: Double, force: Bool = false) async {
        let key = String(format: "%.2f,%.2f", lat, lon)
        if !force, key == lastCoordKey, speedKmh != nil,
           Date().timeIntervalSince(lastFetch) < cacheTTL { return }

        guard var comps = URLComponents(string: "https://winds.mobi/api/2.3/stations/") else { return }
        comps.queryItems = [
            URLQueryItem(name: "near-lat", value: String(lat)),
            URLQueryItem(name: "near-lon", value: String(lon)),
            URLQueryItem(name: "near-distance", value: "30000"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = comps.url else { return }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let stations = try? JSONDecoder().decode([WMStation].self, from: data) else {
            windLogger.info("WatchWind: fetch direct indisponible (réseau/décodage) — on garde le vent du tel")
            return
        }

        let now = Date()
        let target = CLLocation(latitude: lat, longitude: lon)
        let best = stations.compactMap { s -> (station: WMStation, measure: WMMeasure, dist: Double)? in
            guard s.peak != true, s.status != "red",
                  let coords = s.loc?.coordinates, coords.count == 2,
                  s.alt == nil || (s.alt ?? 0) <= maxAltitudeMeters,
                  let m = s.last, m.wAvg != nil,
                  now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(m._id))) < maxAgeSeconds
            else { return nil }
            let d = target.distance(from: CLLocation(latitude: coords[1], longitude: coords[0]))
            return (s, m, d)
        }.min { $0.dist < $1.dist }

        guard let best else {
            windLogger.info("WatchWind: aucune balise fraîche à proximité")
            return
        }

        lastFetch = now
        lastCoordKey = key
        speedKmh = best.measure.wAvg
        gustKmh = best.measure.wMax
        directionDeg = Double(best.measure.wDir ?? 0)
        stationName = best.station.short ?? best.station.name ?? "Balise"
        date = Date(timeIntervalSince1970: TimeInterval(best.measure._id))
        windLogger.info("WatchWind: balise directe → \(self.stationName ?? "?")")
    }

    // MARK: - Décodage minimal de la réponse winds.mobi (clés à tirets)

    private struct WMStation: Decodable {
        let _id: String
        let short: String?
        let name: String?
        let alt: Int?
        let peak: Bool?
        let status: String?
        let loc: WMGeo?
        let last: WMMeasure?
    }
    private struct WMGeo: Decodable { let coordinates: [Double]? }   // [lon, lat] (GeoJSON)
    private struct WMMeasure: Decodable {
        let _id: Int            // timestamp Unix (s)
        let wDir: Int?
        let wAvg: Double?       // km/h
        let wMax: Double?       // km/h
        enum CodingKeys: String, CodingKey {
            case _id
            case wDir = "w-dir"
            case wAvg = "w-avg"
            case wMax = "w-max"
        }
    }
}
