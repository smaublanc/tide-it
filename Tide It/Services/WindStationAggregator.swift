//
//  WindStationAggregator.swift
//  Tide It
//
//  Façade qui agrège plusieurs sources de vent temps réel :
//    - Pioupiou (communautaire, principalement parapente)
//    - AviationWeather METAR (aéroports mondiaux, couverture côtière)
//    - À venir : Holfuy, Météo-France SYNOP
//
//  Fournit une API unifiée pour trouver la station la plus proche d'un port
//  toutes sources confondues, avec déduplication par proximité (500 m).
//
//  Performance : la liste dédupliquée est calculée UNE FOIS après chaque
//  refresh et cachée dans `allStations` (@Published). Les consommateurs
//  lisent cette liste pré-calculée — pas de dedup par appel.
//

import Foundation
import CoreLocation
import Combine
import os.log

@MainActor
final class WindStationAggregator: ObservableObject {
    static let shared = WindStationAggregator()

    /// Rayon de recherche par défaut. Élargi à 60 km pour couvrir « presque tous les
    /// ports du monde » : un aéroport METAR ou une bouée NDBC est presque toujours à
    /// moins de 60 km d'un port. Le classement préfère de toute façon la plus proche,
    /// donc une balise lointaine n'apparaît que s'il n'y a rien de plus près.
    /// `nonisolated` car lue depuis des contextes non-MainActor (default args).
    nonisolated static let defaultSearchRadius: CLLocationDistance = 60_000

    /// Seuil de dédup : on considère deux stations < 500 m comme doublon
    private let dedupeRadiusMeters: CLLocationDistance = 500

    /// Liste consolidée et dédupliquée, mise à jour après chaque refresh
    /// des sources sous-jacentes. Les consommateurs doivent lire ceci, PAS
    /// les services individuels, pour bénéficier de la dédup + cache.
    @Published private(set) var allStations: [WindStation] = []

    private var cancellables = Set<AnyCancellable>()

    /// Dernière zone rafraîchie : sert à NE GARDER que les stations proches avant la
    /// dédup. NDBC publie ~1000 bouées mondiales ; sans ce filtre, la dédup O(n²)
    /// coûterait plusieurs secondes. On borne à ~200 km autour de la zone active.
    private var lastRefreshCoord: CLLocationCoordinate2D?
    private let regionFilterMeters: CLLocationDistance = 200_000

    private init() {
        // Les 5 sources vent publient INDÉPENDAMMENT à l'ouverture (Pioupiou, METAR, Weameter,
        // NDBC, winds.mobi) → sans coalescence, ~5-6 `rebuildDedup()` en rafale, donc autant de
        // re-renders de la carte (MapView observe `allStations`) pile pendant le démarrage à froid
        // de MapKit = lag à la 1ʳᵉ ouverture. On MERGE les 5 flux et on DÉBOUNCE (150 ms) → UN
        // seul rebuild après la rafale. (`refresh()` rappelle `rebuildDedup()` ensuite, donc
        // l'état reste correct même si une source arrive en retard.)
        Publishers.MergeMany(
            PioupiouService.shared.$stations.map { _ in () },
            AviationWeatherService.shared.$stations.map { _ in () },
            WeameterService.shared.$stations.map { _ in () },
            NDBCService.shared.$stations.map { _ in () },
            WindsMobiService.shared.$stations.map { _ in () }
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.rebuildDedup() }
        .store(in: &cancellables)
    }

    // MARK: - Refresh

    /// Rafraîchit toutes les sources en parallèle. AviationWeather nécessite
    /// une bbox → on fournit celle autour du port actif.
    /// La liste dédupliquée `allStations` est reconstruite automatiquement
    /// via les observateurs Combine sur les sources sous-jacentes.
    func refresh(around coord: CLLocationCoordinate2D, force: Bool = false) async {
        lastRefreshCoord = coord
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await PioupiouService.shared.refreshIfNeeded(force: force)
            }
            group.addTask {
                await AviationWeatherService.shared.refresh(around: coord, force: force)
            }
            group.addTask {
                await WeameterService.shared.refreshIfNeeded(force: force)
            }
            group.addTask {
                await NDBCService.shared.refreshIfNeeded(force: force)
            }
            group.addTask {
                // winds.mobi est une requête GÉO (≤20 km autour du spot), pas un fetch global.
                await WindsMobiService.shared.refresh(around: coord, force: force)
            }
        }
        // Re-filtrer autour de la NOUVELLE zone même si aucune source n'a republié
        // (caches encore valides → pas de sink Combine). Sinon, après avoir parcouru
        // la carte loin puis être revenu sur Aujourd'hui, `allStations` resterait
        // centré sur l'ancienne zone et la balise du port disparaîtrait.
        rebuildDedup()
        appLogger.info("[WindAggregator] refresh complete : \(self.allStations.count) stations uniques")
    }

    /// Rafraîchit UNIQUEMENT les sources GLOBALES (Pioupiou `/all`, Weameter, NDBC ~1000 bouées) —
    /// leur contenu est identique quelle que soit la zone. À appeler UNE SEULE FOIS avant une
    /// série de spots : le fan-out background les refetchait par spot (= N× le même gros fichier
    /// NDBC), ce qui pesait sur la batterie. Ne reconstruit pas la liste (voir `refreshGeo`).
    func refreshGlobalOnly(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await PioupiouService.shared.refreshIfNeeded(force: force) }
            group.addTask { await WeameterService.shared.refreshIfNeeded(force: force) }
            group.addTask { await NDBCService.shared.refreshIfNeeded(force: force) }
        }
    }

    /// Rafraîchit les sources GÉO (AviationWeather bbox, winds.mobi ≤20 km) autour d'une zone,
    /// puis reconstruit la liste dédupliquée. Suppose les globales déjà à jour
    /// (`refreshGlobalOnly`). Pensé pour la boucle background « fenêtre GO » multi-spots.
    func refreshGeo(around coord: CLLocationCoordinate2D, force: Bool = false) async {
        lastRefreshCoord = coord
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await AviationWeatherService.shared.refresh(around: coord, force: force) }
            group.addTask { await WindsMobiService.shared.refresh(around: coord, force: force) }
        }
        rebuildDedup()
    }

    /// Reconstruit la liste dédupliquée à partir des sources sous-jacentes.
    /// Appelée automatiquement quand une source publie de nouvelles stations.
    private func rebuildDedup() {
        var combined = PioupiouService.shared.stations
            + AviationWeatherService.shared.stations
            + WeameterService.shared.stations
            + NDBCService.shared.stations
            + WindsMobiService.shared.stations
        // Pré-filtre régional : indispensable avec les ~1000 bouées NDBC mondiales
        // (sinon dédup O(n²) très lourde). Garde la liste proche de la zone active.
        if let c = lastRefreshCoord {
            combined = combined.filter { $0.distance(to: c) <= regionFilterMeters }
        }
        // Court-circuit d'égalité : ne republie `allStations` (@Published → re-render carte) que
        // si la liste a RÉELLEMENT changé. Évite les re-renders gratuits sur refresh cache-hit.
        let next = dedupe(combined)
        if next != allStations { allStations = next }
    }

    /// Retire les doublons géographiques (< 500 m). Garde la plus récente.
    /// Complexité O(n²) mais n'est appelée qu'une fois par refresh.
    private func dedupe(_ list: [WindStation]) -> [WindStation] {
        var result: [WindStation] = []
        result.reserveCapacity(list.count)
        for candidate in list {
            let duplicateIndex = result.firstIndex { existing in
                existing.distance(to: candidate.coordinate) < dedupeRadiusMeters
            }
            if let idx = duplicateIndex {
                // Garder la plus fraîche
                let existingDate = result[idx].reading?.date ?? .distantPast
                let candidateDate = candidate.reading?.date ?? .distantPast
                if candidateDate > existingDate {
                    result[idx] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Lookup

    /// Station la plus proche (toutes sources, fraîche < 30 min)
    func nearestStation(
        to coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> WindStation? {
        nearestStationWithDistance(to: coord, maxDistance: maxDistance)?.station
    }

    /// Meilleure station autour d'un point. On NE garde que les stations fraîches
    /// (les balises « off »/périmées sont ignorées → failover automatique vers une
    /// balise un peu plus loin qui fonctionne). Le classement n'est pas une pure
    /// distance : une balise plus riche en données (température, pression, rafale…)
    /// reçoit un « bonus de proximité » → à distance comparable, la plus complète
    /// devient prioritaire ; mais sur un grand écart, la proximité reste décisive.
    func nearestStationWithDistance(
        to coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> (station: WindStation, distance: CLLocationDistance)? {
        var best: (station: WindStation, distance: CLLocationDistance, score: Double)?
        for station in allStations {
            guard station.reading?.isFresh == true else { continue }   // « off » → exclu
            let d = station.distance(to: coord)
            guard d <= maxDistance else { continue }
            let score = d - qualityBonusMeters(station)   // distance effective
            if best == nil || score < best!.score {
                best = (station, d, score)
            }
        }
        return best.map { ($0.station, $0.distance) }
    }

    /// « Crédit de proximité » accordé à une balise selon la richesse de sa mesure.
    /// Une balise complète (météo + rafale) peut être préférée à une balise nue
    /// jusqu'à ~6,5 km plus proche. Au-delà, la distance brute l'emporte.
    private func qualityBonusMeters(_ station: WindStation) -> Double {
        guard let r = station.reading else { return 0 }
        var bonus: Double = 0
        if r.hasExtraMetrics { bonus += 5_000 }   // température / humidité / pression…
        if r.gustKmh != nil  { bonus += 1_500 }   // fournit la rafale
        // Fraîcheur : départage deux balises proches en faveur de la mesure la plus RÉCENTE
        // (= la plus fiable). Crédit jusqu'à 3 km pour une mesure à l'instant, dégressif
        // jusqu'à 0 à la limite de fraîcheur (60 min). Volontairement modeste → simple
        // arbitrage entre 2-3 balises voisines, sans privilégier une balise lointaine.
        let recency = max(0, 1 - Double(r.ageMinutes) / 60)
        bonus += recency * 3_000
        return bonus
    }

    /// Vrai si au moins une source a une station fraîche < rayon autour du port.
    func hasNearbyStation(
        for port: Port,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> Bool {
        let coord = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
        return nearestStation(to: coord, maxDistance: maxDistance) != nil
    }

    /// Lecture de vent la plus proche pour un port donné, avec métadonnées.
    /// Utilisé par les alertes : on veut prioriser le vent RÉEL avant les prévisions.
    func nearestReading(
        for port: Port,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> (station: WindStation, reading: WindReading, distanceKm: Double)? {
        let coord = CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude)
        guard let result = nearestStationWithDistance(to: coord, maxDistance: maxDistance),
              let reading = result.station.reading else { return nil }
        return (result.station, reading, result.distance / 1000)
    }

    /// Lecture balise la plus proche d'une COORDONNÉE (sans objet `Port`) — utile en
    /// arrière-plan où l'on ne dispose que des lat/lon persistés.
    func nearestReading(
        forCoordinate coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = defaultSearchRadius
    ) -> WindReading? {
        nearestStationWithDistance(to: coord, maxDistance: maxDistance)?.station.reading
    }

    /// HOULE réelle la plus proche (bouées NDBC). Gating INDÉPENDANT du vent : une bouée peut publier
    /// une houle fraîche même si sa mesure de vent est périmée → on teste `wave.isFresh`, jamais
    /// `reading?.isFresh`. Classement par distance BRUTE (pas de bonus de richesse). Rayon LARGE
    /// (140 km) car les bouées sont au large et éparses. Sert à l'affinage jour-J de la note surf.
    func nearestWaveReading(
        to coord: CLLocationCoordinate2D,
        maxDistance: CLLocationDistance = 140_000
    ) -> (station: WindStation, wave: WaveReading, distanceKm: Double)? {
        var best: (station: WindStation, wave: WaveReading, distance: CLLocationDistance)?
        for station in allStations {
            guard let wave = station.wave, wave.isFresh else { continue }
            let d = station.distance(to: coord)
            guard d <= maxDistance else { continue }
            if best == nil || d < best!.distance { best = (station, wave, d) }
        }
        return best.map { ($0.station, $0.wave, $0.distance / 1000) }
    }

    /// Houle réelle la plus proche d'un port (surcharge confort).
    func nearestWaveReading(
        for port: Port,
        maxDistance: CLLocationDistance = 140_000
    ) -> (station: WindStation, wave: WaveReading, distanceKm: Double)? {
        nearestWaveReading(to: CLLocationCoordinate2D(latitude: port.latitude, longitude: port.longitude),
                           maxDistance: maxDistance)
    }
}

// MARK: - Weameter (stations WeeWX)

/// Source de vent « Weameter » : petit réseau de balises côtières françaises
/// (Bassin d'Arcachon, Médoc) tournant sous WeeWX. Pas d'API de découverte → on
/// interroge directement le JSON live de chaque station connue
/// (`https://weameter.com/stations/<slug>/json/weewx_data.json`). Chaque station
/// porte ses coordonnées → l'agrégateur en déduit la proximité comme pour les autres.
@MainActor
final class WeameterService: ObservableObject {
    static let shared = WeameterService()

    @Published private(set) var stations: [WindStation] = []
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 180  // 3 min

    /// Balises Weameter connues (slug = chemin sous /stations/). Liste maintenue à la
    /// main : weameter.com ne fournit pas d'endpoint de découverte.
    private let slugs = ["andernos", "pauillac", "lachanau"]

    private init() {}

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Rafraîchit toutes les balises connues si le cache est expiré (ou forceRefresh).
    func refreshIfNeeded(force: Bool = false) async {
        if !force, let last = lastFetch,
           Date().timeIntervalSince(last) < cacheTTL, !stations.isEmpty {
            return
        }

        let slugsCopy = slugs
        let fetched = await withTaskGroup(of: WindStation?.self) { group -> [WindStation] in
            for slug in slugsCopy {
                group.addTask { await WeameterService.fetchStation(slug: slug) }
            }
            var result: [WindStation] = []
            for await station in group { if let station { result.append(station) } }
            return result
        }

        if !fetched.isEmpty {
            self.stations = fetched
            self.lastFetch = Date()
        }
        appLogger.info("[Weameter] \(fetched.count)/\(slugsCopy.count) balises chargées")
    }

    // MARK: - Network + parsing (nonisolated : tourne hors du main thread)

    private nonisolated static func fetchStation(slug: String) async -> WindStation? {
        guard let url = URL(string: "https://weameter.com/stations/\(slug)/json/weewx_data.json") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = root["current"] as? [String: Any],
                  let station = root["station"] as? [String: Any] else { return nil }

            guard let lat = doubleValue(station["latitude_dd"]),
                  let lon = doubleValue(station["longitude_dd"]) else { return nil }

            let unitLabel = (root["unit_label"] as? [String: Any])?["windSpeed"] as? String
            let name = (station["location"] as? String)?
                .replacingOccurrences(of: ", France", with: "") ?? "Weameter \(slug)"

            var reading: WindReading?
            if let speed = firstNumber(current["windspeed"] as? String),
               let date = epochDate(current["epoch"]) {
                let dir = firstNumber(current["winddir"] as? String) ?? 0
                let gust = firstNumber(current["windGust"] as? String)
                reading = WindReading(
                    date: date,
                    speedAvgKmh: toKmh(speed, unitLabel: unitLabel),
                    gustKmh: gust.map { toKmh($0, unitLabel: unitLabel) },
                    minKmh: nil,
                    directionDegrees: dir,
                    // Mesures additionnelles WeeWX (°C / % / hPa — tolérant à la virgule FR).
                    temperatureC: firstNumber(current["outTemp"] as? String),
                    humidityPct: firstNumber(current["outHumidity"] as? String),
                    dewpointC: firstNumber(current["dewpoint"] as? String),
                    pressureHpa: firstNumber(current["barometer"] as? String),
                    pressureTrendHpa: firstNumber(current["barometer_trend"] as? String)
                )
            }

            return WindStation(
                id: "weameter_\(slug)",
                name: name,
                source: .weameter,
                latitude: lat,
                longitude: lon,
                reading: reading
            )
        } catch {
            return nil
        }
    }

    /// Convertit une vitesse vers km/h selon l'unité libellée par la station
    /// (nœuds / m·s⁻¹ / mph / défaut km/h). `internal` pour les tests.
    nonisolated static func toKmh(_ value: Double, unitLabel: String?) -> Double {
        let u = (unitLabel ?? "").lowercased()
        if u.contains("oelig") || u.contains("œud") || u.contains("oeud") || u.contains("kt") || u.contains("knot") {
            return value * 1.852
        }
        if u.contains("m/s") || u.contains("mps") || u.contains("m·s") { return value * 3.6 }
        if u.contains("mph") { return value * 1.609344 }
        return value   // km/h ou inconnu
    }

    /// Extrait le premier nombre d'une chaîne localisée ("12,7 nœuds" → 12.7, "234°" → 234).
    /// `internal` pour les tests.
    nonisolated static func firstNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let s = raw.replacingOccurrences(of: ",", with: ".")
        var num = ""
        for ch in s {
            if ch.isNumber || ch == "." || (ch == "-" && num.isEmpty) {
                num.append(ch)
            } else if !num.isEmpty {
                break
            }
        }
        return Double(num)
    }

    private nonisolated static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) ?? firstNumber(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private nonisolated static func epochDate(_ any: Any?) -> Date? {
        if let s = any as? String, let t = Double(s) { return Date(timeIntervalSince1970: t) }
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }
}

// MARK: - NDBC (bouées marines NOAA — couverture mondiale)

/// Source « bouées » : NOAA National Data Buoy Center. Un SEUL fichier global
/// `latest_obs.txt` contient la dernière mesure de TOUTES les stations (bouées +
/// stations côtières C-MAN), avec position, vent, pression, température, point de
/// rosée. Idéal pour couvrir les ports du monde entier (là où il n'y a ni Pioupiou
/// ni aéroport METAR proche).
@MainActor
final class NDBCService: ObservableObject {
    static let shared = NDBCService()

    @Published private(set) var stations: [WindStation] = []
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 1800   // 30 min (les bouées publient ~horaire)
    private let endpoint = "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt"

    private init() {}

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func refreshIfNeeded(force: Bool = false) async {
        if !force, let last = lastFetch,
           Date().timeIntervalSince(last) < cacheTTL, !stations.isEmpty {
            return
        }
        guard let url = URL(string: endpoint) else { return }
        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            // Décodage + parsing du fichier (~1000 lignes) hors du main thread.
            let parsed = await Task.detached(priority: .utility) {
                Self.parse(String(decoding: data, as: UTF8.self))
            }.value
            if !parsed.isEmpty {
                self.stations = parsed
                self.lastFetch = Date()
            }
            appLogger.info("[NDBC] \(parsed.count) bouées avec vent chargées")
        } catch {
            appLogger.warning("[NDBC] Erreur fetch: \(error.localizedDescription)")
        }
    }

    /// Parse le fichier texte à colonnes fixes (séparées par espaces). « MM » = manquant.
    /// Colonnes : STN LAT LON YYYY MM DD hh mm WDIR WSPD GST WVHT DPD APD MWD PRES PTDY ATMP WTMP DEWP VIS TIDE
    nonisolated static func parse(_ text: String) -> [WindStation] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var out: [WindStation] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 11 else { continue }
            guard let lat = Double(f[1]), let lon = Double(f[2]),
                  let wdir = num(f[8]), let wspd = num(f[9]) else { continue }   // vent requis
            guard let yr = Int(f[3]), let mo = Int(f[4]), let dy = Int(f[5]),
                  let hh = Int(f[6]), let mm = Int(f[7]) else { continue }
            var c = DateComponents()
            c.year = yr; c.month = mo; c.day = dy; c.hour = hh; c.minute = mm
            c.timeZone = TimeZone(identifier: "UTC")
            guard let date = cal.date(from: c) else { continue }

            let gust = f.count > 10 ? num(f[10]) : nil
            let pres = f.count > 15 ? num(f[15]) : nil
            let atmp = f.count > 17 ? num(f[17]) : nil
            let dewp = f.count > 19 ? num(f[19]) : nil

            let reading = WindReading(
                date: date,
                speedAvgKmh: wspd * 3.6,                 // m/s → km/h
                gustKmh: gust.map { $0 * 3.6 },
                minKmh: nil,
                directionDegrees: wdir,
                temperatureC: atmp,
                humidityPct: nil,
                dewpointC: dewp,
                pressureHpa: pres,
                pressureTrendHpa: nil
            )
            // HOULE réelle (NDBC) : WVHT/DPD/APD/MWD/WTMP — déjà métriques (m, s, deg, °C ; PAS de ×3.6).
            // Construite seulement si WVHT présent (beaucoup de stations C-MAN/baie n'ont pas de houle).
            let wave: WaveReading? = {
                guard f.count > 11, let h = Self.num(f[11]) else { return nil }
                return WaveReading(
                    date: date,
                    heightM: h,
                    periodS: f.count > 12 ? Self.num(f[12]) : nil,
                    directionDegrees: f.count > 14 ? Self.num(f[14]) : nil
                )
            }()
            out.append(WindStation(
                id: "ndbc_\(f[0])",
                name: "Bouée \(f[0])",
                source: .ndbc,
                latitude: lat,
                longitude: lon,
                reading: reading,
                wave: wave
            ))
        }
        return out
    }

    /// Convertit un champ NDBC en nombre (« MM » → nil).
    nonisolated static func num(_ s: String) -> Double? {
        s == "MM" ? nil : Double(s)
    }
}

// MARK: - Winds.mobi (agrégat de réseaux de balises : Holfuy, FFVL, Romma, MeteoSwiss…) ─────────
//
//  API REST publique SANS CLÉ : GET https://winds.mobi/api/2.3/stations/
//    ?near-lat=&near-lon=&near-distance=<mètres>&limit=
//  Serveur AGPL-3.0 → appeler l'API depuis une app fermée ne crée AUCUNE obligation copyleft
//  (l'AGPL ne pèse que sur qui HÉBERGE le serveur). Données = observations réelles de balises.
//
//  Filtres demandés : (1) balise ≤ 20 km du spot (paramètre `near-distance` côté serveur) ;
//  (2) « pas dans les terres » → on écarte les balises de montagne/parapente. Faute de trait de
//  côte embarqué (offline), heuristique : on exclut `peak == true` et les altitudes élevées.
//  `alt`/`peak` sont des champs natifs winds.mobi (réseau parapente → altitude renseignée).
//  ⚠ winds.mobi RÉEXPOSE Pioupiou : les doublons sont fusionnés par la dédup 500 m de l'agrégateur.
@MainActor
final class WindsMobiService: ObservableObject {
    static let shared = WindsMobiService()

    @Published private(set) var stations: [WindStation] = []
    private var lastFetchKey: String?
    private var lastFetch: Date?
    private let cacheTTL: TimeInterval = 180   // 3 min

    /// Rayon de recherche autour du spot (filtré côté serveur). Assoupli 20→30 km pour faire
    /// remonter davantage de balises Holfuy/FFVL/Romma sur les façades.
    nonisolated static let searchRadiusMeters = 30_000
    /// « Pas dans les terres » : on écarte montagne/parapente. Heuristique altitude (m), assouplie
    /// 50→120 pour garder les balises de dune/falaise côtières. Réglable.
    private let maxAltitudeMeters = 120

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Rafraîchit les balises ≤ 20 km autour du spot (requête géo, cache 3 min par zone).
    func refresh(around coord: CLLocationCoordinate2D, force: Bool = false) async {
        let key = String(format: "%.2f,%.2f", coord.latitude, coord.longitude)
        if !force, key == lastFetchKey, let last = lastFetch,
           Date().timeIntervalSince(last) < cacheTTL, !stations.isEmpty {
            return
        }
        do {
            let fetched = try await fetchNearby(coord)
            self.stations = fetched
            self.lastFetchKey = key
            self.lastFetch = Date()
            appLogger.info("[WindsMobi] \(fetched.count) balises côtières ≤20km")
        } catch {
            appLogger.warning("[WindsMobi] fetch: \(error.localizedDescription)")
        }
    }

    private func fetchNearby(_ coord: CLLocationCoordinate2D) async throws -> [WindStation] {
        var comps = URLComponents(string: "https://winds.mobi/api/2.3/stations/")
        comps?.queryItems = [
            URLQueryItem(name: "near-lat", value: String(coord.latitude)),
            URLQueryItem(name: "near-lon", value: String(coord.longitude)),
            URLQueryItem(name: "near-distance", value: String(Self.searchRadiusMeters)),
            URLQueryItem(name: "limit", value: "50")
        ]
        guard let url = comps?.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let stations = try JSONDecoder().decode([Station].self, from: data)
        return stations.compactMap { windStation(from: $0) }
    }

    private func windStation(from s: Station) -> WindStation? {
        // loc.coordinates = [longitude, latitude] (GeoJSON)
        guard let coords = s.loc?.coordinates, coords.count == 2 else { return nil }
        let lon = coords[0], lat = coords[1]
        // « Pas dans les terres » : exclure sommets + altitude élevée (balises montagne/parapente).
        if s.peak == true { return nil }
        if let alt = s.alt, alt > maxAltitudeMeters { return nil }
        if s.status == "red" { return nil }   // red = hors-ligne

        let reading: WindReading?
        if let m = s.last {
            reading = WindReading(
                date: Date(timeIntervalSince1970: TimeInterval(m._id)),
                speedAvgKmh: m.wAvg ?? 0,
                gustKmh: m.wMax,
                minKmh: nil,
                directionDegrees: Double(m.wDir ?? 0),
                temperatureC: m.temp,
                humidityPct: m.hum,
                pressureHpa: m.pres?.qnh
            )
        } else {
            reading = nil
        }
        return WindStation(
            id: "wm_\(s._id)",
            name: s.short ?? s.name ?? "Balise",
            source: .windsMobi,
            latitude: lat,
            longitude: lon,
            reading: reading
        )
    }

    // MARK: Decodable (clés JSON à tirets → CodingKeys)
    private struct Station: Decodable {
        let _id: String
        let short: String?
        let name: String?
        let alt: Int?
        let peak: Bool?
        let status: String?
        let loc: GeoPoint?
        let last: Measure?
    }
    private struct GeoPoint: Decodable { let coordinates: [Double]? }
    private struct Measure: Decodable {
        let _id: Int          // timestamp Unix (s)
        let wDir: Int?
        let wAvg: Double?
        let wMax: Double?
        let temp: Double?
        let hum: Double?
        let pres: Pressure?
        enum CodingKeys: String, CodingKey {
            case _id
            case wDir = "w-dir"
            case wAvg = "w-avg"
            case wMax = "w-max"
            case temp, hum, pres
        }
    }
    private struct Pressure: Decodable { let qnh: Double? }
}

// MARK: - Magasin générique d'historique vent observé (TOUTES balises)

/// Accumule les relevés balise (toutes sources : Pioupiou, METAR, NDBC, winds.mobi, Weameter…) par
/// station → socle UNIVERSEL du tracé « vent réel récent ». Chaque relevé live est enregistré ; les
/// sources avec archive (Pioupiou) le pré-remplissent dense via `merge`. Borné + persisté.
/// Honnête : on ne stocke que des mesures RÉELLES (jamais d'interpolation).
@MainActor
final class WindHistoryStore: ObservableObject {
    static let shared = WindHistoryStore()

    struct Sample: Codable { let t: Date; let avg: Double; let gust: Double?; let dir: Double }

    @Published private(set) var buffers: [String: [Sample]] = [:]
    private let maxAge: TimeInterval = 5 * 3600   // fenêtre 5 h
    private let maxSamples = 160
    private let storeKey = "windHistoryBuffers_v1"

    private init() { load() }

    /// Enregistre un relevé live (n'importe quelle source). Anti-doublon à la minute.
    func record(stationId: String, reading: WindReading) {
        guard !stationId.isEmpty else { return }
        var arr = buffers[stationId] ?? []
        if arr.contains(where: { abs($0.t.timeIntervalSince(reading.date)) < 60 }) { return }
        arr.append(Sample(t: reading.date, avg: reading.speedAvgKmh, gust: reading.gustKmh, dir: reading.directionDegrees))
        prune(&arr); buffers[stationId] = arr; save()
    }

    /// Fusionne une série backfill (archive dense) — dédup par minute.
    func merge(stationId: String, readings: [WindReading]) {
        guard !stationId.isEmpty, !readings.isEmpty else { return }
        var arr = buffers[stationId] ?? []
        var minutes = Set(arr.map { Int($0.t.timeIntervalSince1970 / 60) })
        for r in readings {
            let m = Int(r.date.timeIntervalSince1970 / 60)
            if minutes.insert(m).inserted {
                arr.append(Sample(t: r.date, avg: r.speedAvgKmh, gust: r.gustKmh, dir: r.directionDegrees))
            }
        }
        prune(&arr); buffers[stationId] = arr; save()
    }

    /// Série affichable (triée, fraîche) pour une station — vide si rien encore.
    func history(for stationId: String) -> [WindReading] {
        (buffers[stationId] ?? []).map {
            WindReading(date: $0.t, speedAvgKmh: $0.avg, gustKmh: $0.gust, minKmh: nil, directionDegrees: $0.dir)
        }
    }

    /// Purge l'historique d'une station (à câbler dans TideService.purgePortState si besoin).
    func purge(stationId: String) {
        guard buffers[stationId] != nil else { return }
        buffers.removeValue(forKey: stationId); save()
    }

    private func prune(_ arr: inout [Sample]) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        arr = arr.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
        if arr.count > maxSamples { arr.removeFirst(arr.count - maxSamples) }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(buffers) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let b = try? JSONDecoder().decode([String: [Sample]].self, from: d) else { return }
        buffers = b
    }
}
