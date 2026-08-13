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

    /// Clé de source, IDENTIQUE au `rawValue` de `WindStation.Source.windsMobi` côté iPhone —
    /// c'est le contrat documenté dans `docs/blocklist.json`. Couper `windsMobi` dans le fichier
    /// distant doit faire taire les deux appareils, pas un seul.
    private static let sourceKey = "windsMobi"

    private var lastFetch: Date = .distantPast
    private var lastCoordKey: String = ""
    private let cacheTTL: TimeInterval = 180        // 3 min : on ne re-fetch pas plus souvent
    private let maxAgeSeconds: TimeInterval = 60 * 60   // mesure < 60 min
    private let maxAltitudeMeters = 120             // exclut les balises montagne / parapente

    /// 15 km — la MÊME valeur que `WindStationAggregator.defaultSearchRadius` sur iPhone, et
    /// pour la même raison. Était 30 km : la Watch pouvait donc afficher, comme « vent réel »,
    /// une mesure prise à 30 km. C'est exactement le défaut corrigé sur le téléphone (au Cap
    /// Ferret, « réel 9 nds » contre 17 prévus, la mesure venant d'une station à l'intérieur
    /// des terres) — mais la correction n'avait pas été portée ici.
    ///
    /// C'est pourtant sur la Watch que ça compte le plus : c'est l'appareil qu'on a au poignet
    /// À LA PLAGE, sans téléphone, au moment de décider si on gonfle l'aile. Une confirmation
    /// doit venir du même endroit ; sinon, ne rien montrer.
    ///
    /// Les deux constantes ne peuvent pas être partagées (cibles séparées, la Watch est
    /// FS-synced et ne voit pas `Tide It/Services`). Si l'une change, changer l'autre.
    private let searchRadiusMeters = 15_000

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
            URLQueryItem(name: "near-distance", value: String(searchRadiusMeters)),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = comps.url else { return }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let stations = try? JSONDecoder().decode([WMStation].self, from: data) else {
            windLogger.info("WatchWind: fetch direct indisponible (réseau/décodage) — on garde le vent du tel")
            return
        }

        // LISTE DE RETRAIT — la promesse faite aux exploitants vaut aussi ici. L'iPhone filtrait
        // (`WindStationAggregator.rebuildDedup`), la Watch non : une balise retirée disparaissait
        // du téléphone et restait au poignet. Lue en UN coup (`snapshot`) et non balise par
        // balise : un acteur imposerait une suspension par élément dans le tri ci-dessous.
        await WatchSourceBlocklist.shared.refreshIfNeeded()
        let blocked = await WatchSourceBlocklist.shared.snapshot()
        // Le fournisseur entier peut être coupé depuis le fichier distant.
        if blocked.sources.contains(Self.sourceKey) {
            windLogger.info("WatchWind: source \(Self.sourceKey) retirée par la liste de retrait")
            return
        }

        let now = Date()
        let target = CLLocation(latitude: lat, longitude: lon)
        let best = stations.compactMap { s -> (station: WMStation, measure: WMMeasure, dist: Double)? in
            guard s.peak != true, s.status != "red",
                  // MÊME convention d'identifiant que l'iPhone (`wm_<id>`) : sans elle, une
                  // entrée de la liste ne retirerait la balise que d'un des deux appareils.
                  !blocked.stations.contains("wm_\(s._id)"),
                  let coords = s.loc?.coordinates, coords.count == 2,
                  s.alt == nil || (s.alt ?? 0) <= maxAltitudeMeters,
                  let m = s.last, m.wAvg != nil,
                  // La DIRECTION est exigée ici, et non complétée par un `?? 0` plus bas :
                  // sans elle, la flèche pointait plein Nord — une mesure inventée. Écarter la
                  // balise laisse le vent fourni par le téléphone prendre le relais, ce qui
                  // vaut mieux qu'un cap faux affiché avec aplomb.
                  m.wDir != nil,
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
        // Jamais de `?? 0` sur une mesure : ce serait un cap plein Nord indiscernable d'un vent
        // réellement mesuré au nord. Le filtre ci-dessus garantit déjà `wDir != nil` ; cette
        // écriture fait que la garantie ne repose pas sur un invariant à distance.
        directionDeg = best.measure.wDir.map(Double.init)
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
