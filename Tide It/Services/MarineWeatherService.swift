//
//  MarineWeatherService.swift
//  Tide It
//
//  Service de conditions marines (vagues) via Open-Meteo Marine API
//

import Foundation
import CoreLocation
import os.log

// MARK: - Marine Conditions Model
struct MarineConditions: Codable, Equatable {
    let waveHeight: Double          // Hauteur significative (m)
    let wavePeriod: Double          // Période de la houle (s)
    let waveDirection: Double       // Direction de la houle (°)
    let windWaveHeight: Double?     // Hauteur des vagues de vent (m)
    let swellHeight: Double?        // Hauteur de la houle (m)
    let swellPeriod: Double?        // Période de la houle longue (s)
    let swellDirection: Double?     // Direction de la houle longue (°)
    let waterTemperature: Double?   // Température de l'eau (°C)

    /// Le modèle marine a-t-il réellement fourni une lecture de vague/houle ?
    /// `init(from:)` retombe sur 0 quand le point n'est pas couvert (spot très abrité, plan d'eau
    /// intérieur, réponse partielle) : sans ce témoin, ce 0 FABRIQUÉ se lit comme une mesure
    /// « mer plate » — et le moteur surf notait dessus. Une vraie mer à 0,00 m n'existe pas ;
    /// une houle nulle mais mesurée arrive toujours avec sa période ou sa partition.
    var hasWaveData: Bool { swellHeight != nil || waveHeight > 0 || wavePeriod > 0 }

    var waveDirectionName: String {
        let directions = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let index = Int((waveDirection + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return directions[max(0, min(index, directions.count - 1))]
    }

    var seaState: SeaState {
        switch waveHeight {
        case 0..<0.1: return .calm
        case 0.1..<0.5: return .smooth
        case 0.5..<1.25: return .slight
        case 1.25..<2.5: return .moderate
        case 2.5..<4: return .rough
        case 4..<6: return .veryRough
        case 6..<9: return .high
        default: return .veryHigh
        }
    }

    enum SeaState: String {
        case calm = "Calme"
        case smooth = "Belle"
        case slight = "Peu agitée"
        case moderate = "Agitée"
        case rough = "Forte"
        case veryRough = "Très forte"
        case high = "Grosse"
        case veryHigh = "Très grosse"

        var color: String {
            switch self {
            case .calm, .smooth: return "green"
            case .slight: return "cyan"
            case .moderate: return "yellow"
            case .rough: return "orange"
            case .veryRough, .high, .veryHigh: return "red"
            }
        }
    }
}

extension MarineConditions {
    /// Construit des conditions marines à partir d'une heure de prévision (pour scorer le futur
    /// dans le mode AUTO). Les champs requis retombent sur la houle puis 0 si tout est absent.
    init(from f: HourlyForecast) {
        self.init(
            waveHeight: f.waveHeight ?? f.swellHeight ?? 0,
            wavePeriod: f.wavePeriod ?? f.swellPeriod ?? 0,
            waveDirection: f.waveDirection ?? f.swellDirection ?? 0,
            windWaveHeight: f.windWaveHeight,
            swellHeight: f.swellHeight,
            swellPeriod: f.swellPeriod,
            swellDirection: f.swellDirection,
            waterTemperature: f.waterTemperature
        )
    }
}

// MARK: - Open-Meteo Marine API Response

// MARK: - Hourly Forecast Response (Marine)
private struct MarineHourlyResponse: Codable {
    let hourly: HourlyMarine?

    struct HourlyMarine: Codable {
        let time: [String]?
        let wave_height: [Double?]?
        let wave_period: [Double?]?
        let wave_direction: [Double?]?
        let swell_wave_height: [Double?]?
        let swell_wave_period: [Double?]?
        let swell_wave_direction: [Double?]?
        // Champs surf ajoutés à la requête (cf. fetchMarineHourly). Tous Optionnels :
        // si Open-Meteo ne fournit pas un champ pour ce point, le décodage reste valide.
        let swell_wave_peak_period: [Double?]?
        let wind_wave_height: [Double?]?
        let wind_wave_period: [Double?]?
        let secondary_swell_wave_height: [Double?]?
        let secondary_swell_wave_period: [Double?]?
        let secondary_swell_wave_direction: [Double?]?
        let tertiary_swell_wave_height: [Double?]?
        let tertiary_swell_wave_period: [Double?]?
        let tertiary_swell_wave_direction: [Double?]?
        let sea_surface_temperature: [Double?]?
    }
}

// MARK: - Ensemble vent multi-modèles (Open-Meteo, AROME prioritaire)
//
// On interroge 3 modèles indépendants en une requête : AROME HD 1,3 km (Météo-France,
// le plus fin pour le vent côtier/thermique en France), ICON (DWD, Europe/monde) et GFS
// (NOAA, monde + HRRR US). Open-Meteo suffixe alors chaque variable par le nom du modèle.
// On combine ensuite par moyenne pondérée (AROME 0,5 · ICON 0,3 · GFS 0,2) et on dérive
// un indice de FIABILITÉ à partir de l'accord entre modèles → « Sorties Parfaites » plus juste.
private struct WindEnsembleResponse: Codable {
    let hourly: Hourly?

    struct Hourly: Codable {
        let time: [String]?
        // AROME (Météo-France) — meilleure résolution, France
        let wind_speed_10m_meteofrance_seamless: [Double?]?
        let wind_gusts_10m_meteofrance_seamless: [Double?]?
        let wind_direction_10m_meteofrance_seamless: [Double?]?
        // ICON (DWD)
        let wind_speed_10m_icon_seamless: [Double?]?
        let wind_gusts_10m_icon_seamless: [Double?]?
        let wind_direction_10m_icon_seamless: [Double?]?
        // GFS (NOAA)
        let wind_speed_10m_gfs_seamless: [Double?]?
        let wind_gusts_10m_gfs_seamless: [Double?]?
        let wind_direction_10m_gfs_seamless: [Double?]?
    }
}

// MARK: - Extras météo (modèle best_match — variables non ventées)
private struct WeatherExtrasResponse: Codable {
    let hourly: HourlyExtras?

    struct HourlyExtras: Codable {
        let time: [String]?
        let temperature_2m: [Double?]?
        let weather_code: [Int?]?
        let relative_humidity_2m: [Double?]?
        let pressure_msl: [Double?]?
        let uv_index: [Double?]?
        let precipitation: [Double?]?
        let precipitation_probability: [Double?]?
    }
}

// MARK: - Combinaison d'ensemble (logique pure, testable)

/// Une mesure de vent d'un modèle. L'ORDRE du tableau vaut priorité (cf. `WindEnsemble.blend`).
struct WindModelReading {
    let speed: Double?
    let gust: Double?
    let dir: Double?
}

enum WindEnsemble {
    /// Ordre de PRÉFÉRENCE — du mieux résolu au plus grossier. Ce n'est plus une pondération.
    ///
    /// `meteofrance_seamless` enchaîne AROME HD (1,3 km) sur les 2 premiers jours, AROME (2,5 km),
    /// puis ARPEGE au-delà : c'est la meilleure chaîne disponible sur la France. ICON (11 km) et
    /// GFS (27 km) ne servent plus que de FILET pour les spots hors domaine français, et de
    /// second avis pour mesurer la confiance.
    static let modelPriority = ["meteofrance_seamless", "icon_seamless", "gfs_seamless"]

    /// Combine les modèles pour une heure donnée.
    ///
    /// ⚠️ LA VALEUR N'EST PLUS UNE MOYENNE PONDÉRÉE, ET C'EST UN CORRECTIF DE FOND.
    ///
    /// Moyenner réduit l'erreur quand les modèles se trompent de façon INDÉPENDANTE et
    /// aléatoire. Ici, non : à 11 km (ICON) et 27 km (GFS) de maille, un point côtier tombe
    /// dans une case qui mélange terre et mer. Leur erreur n'est pas du bruit, c'est une
    /// incapacité STRUCTURELLE à voir le trait de côte — et la moyenner revient à l'importer.
    ///
    /// Mesuré au Cap Ferret, 18 h, 7 août 2026 : AROME 18,0 nds (front de mer), ICON 7,6, GFS
    /// 6,1. La moyenne pondérée sortait 12,5 nds — soit un tiers de vent en moins qu'annoncé
    /// par le seul modèle capable de résoudre la côte. Andernos, dans le Bassin abrité, s'en
    /// trouvait plus venté que le front de mer : l'ordre physique était inversé.
    ///
    /// Désormais : la vitesse, la rafale ET la direction viennent du MÊME modèle, le mieux
    /// résolu qui réponde. Prendre la direction d'un autre donnerait un cap qu'aucun modèle
    /// n'a prévu — or on/off/side-shore décide d'une session.
    ///
    /// L'écart entre modèles reste calculé : il ne pilote plus la valeur, seulement la
    /// CONFIANCE. C'est son rôle légitime — un désaccord est une incertitude, pas une valeur.
    ///
    /// - Returns: nil si aucun modèle n'a fourni de vitesse.
    nonisolated static func blend(_ readings: [WindModelReading])
        -> (speed: Double, gust: Double?, dir: Double, confidence: Double, count: Int)? {
        let valid = readings.filter { $0.speed != nil }
        guard let best = valid.first, let speed = best.speed else { return nil }

        // Rafale et direction du MÊME modèle. S'il ne les publie pas, on complète avec le
        // suivant plutôt que de perdre l'information — mais jamais en mélangeant des valeurs.
        let gust = best.gust ?? valid.first(where: { $0.gust != nil })?.gust
        let dir  = best.dir  ?? valid.first(where: { $0.dir  != nil })?.dir ?? 0

        // Confiance : étalement des vitesses entre TOUS les modèles disponibles.
        let speeds = valid.compactMap { $0.speed }
        var confidence: Double
        if speeds.count >= 2, let mn = speeds.min(), let mx = speeds.max() {
            // 0 km/h d'écart → 1,0 ; 18 km/h d'écart ou plus → 0,2.
            confidence = max(0.2, min(1.0, 1 - (mx - mn) / 18.0))
        } else {
            confidence = 0.55  // un seul modèle → pas de recoupement possible
        }

        // PLAFOND QUAND LE MODÈLE FIN A DISPARU.
        //
        // La chaîne Météo-France s'arrête vers J+5 ; au-delà il ne reste qu'ICON (11 km) et GFS
        // (27 km). Or ces deux-là s'accordent souvent — parce qu'ils commettent la MÊME erreur :
        // à cette maille, un point côtier tombe dans une case mêlant terre et mer, et tous deux
        // sous-lisent le vent de mer. Leur accord n'est donc pas une preuve, c'est un angle mort
        // partagé. Sans ce plafond, l'app annonçait sa plus grande confiance pile là où elle en
        // avait le moins — et le repérage anticipé, qui choisit la fenêtre « la plus sûre »,
        // aurait préféré J+6 à J+3.
        if readings.first?.speed == nil {
            confidence = min(confidence, 0.5)
        }

        return (speed, gust, dir, confidence, valid.count)
    }
}

/// Prévision horaire simplifiée pour le planificateur
struct HourlyForecast: Equatable {
    let time: Date
    // var (pas let) : permet l'affinage jour-J via les helpers de copie withWind/withSwell
    // (la copie de struct porte automatiquement TOUS les autres champs → zéro risque de zéroter).
    var windSpeedKmh: Double
    var windGustKmh: Double?
    var windDirection: Double
    let temperature: Double?
    let weatherCode: Int?
    let waveHeight: Double?
    let wavePeriod: Double?
    var swellHeight: Double?
    var swellPeriod: Double?
    // — Champs MARINE étendus (surf). Optionnels + défaut nil → aucun call-site existant
    //   à modifier ; la prévision WeatherKit de repli (TodayView) les laisse nil (pas de houle).
    //   En mémoire uniquement (HourlyForecast n'est PAS Codable) : pas de migration de schéma.
    var waveDirection: Double? = nil          // direction mer totale (deg, provenance)
    var swellDirection: Double? = nil         // direction de la houle dominante (deg) — croisée au cap du spot
    var swellPeakPeriod: Double? = nil        // période de PIC de la houle (s) — plus juste que la moyenne pour le surf
    var windWaveHeight: Double? = nil         // mer du vent (m) — sert au ratio de pureté houle/clapot
    var secondarySwellHeight: Double? = nil   // 2e train de houle (m) — interférence multi-houle
    var secondarySwellPeriod: Double? = nil
    var secondarySwellDirection: Double? = nil
    var tertiarySwellHeight: Double? = nil     // 3e train de houle (m) — optionnel
    var tertiarySwellPeriod: Double? = nil
    var tertiarySwellDirection: Double? = nil
    var waterTemperature: Double? = nil        // température de surface de la mer (°C) — conseil combinaison
    var humidity: Double? = nil               // %
    var pressure: Double? = nil               // hPa (niveau mer)
    var uvIndex: Double? = nil                // indice UV
    var precipitationProbability: Double? = nil // %
    /// Fiabilité de la prévision vent : 0–1 (accord entre modèles AROME/ICON/GFS).
    /// nil si un seul modèle disponible n'a pas pu être recoupé.
    var windConfidence: Double? = nil
}

extension HourlyForecast {
    /// Copie en ne changeant QUE le vent (la copie de struct porte tous les autres champs).
    func withWind(speed: Double, gust: Double?, direction: Double) -> HourlyForecast {
        var c = self
        c.windSpeedKmh = speed
        c.windGustKmh = gust
        c.windDirection = direction
        return c
    }
    /// Copie en ne changeant QUE la houle dominante (hauteur/période/pic/direction). `windWaveHeight`
    /// est VOLONTAIREMENT laissée intacte (la Hs bouée est totale, pas une partition → pureté honnête).
    func withSwell(height: Double?, period: Double?, peak: Double?, direction: Double?) -> HourlyForecast {
        var c = self
        if let height { c.swellHeight = height }
        if let period { c.swellPeriod = period }
        if let peak { c.swellPeakPeriod = peak }
        if let direction { c.swellDirection = direction }
        return c
    }
}

private struct SeaTemperatureResponse: Codable {
    let current: CurrentTemp?

    struct CurrentTemp: Codable {
        let sea_surface_temperature: Double?
    }
}

// MARK: - Marine Weather Service
@MainActor
class MarineWeatherService: ObservableObject {
    static let shared = MarineWeatherService()

    @Published var currentConditions: MarineConditions?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let baseURL = "https://marine-api.open-meteo.com/v1/marine"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()


    /// Conditions marines COURANTES du port — DÉRIVÉES de la prévision horaire (déjà chargée par
    /// TodayView → cache partagé), au lieu d'un 2ᵉ appel réseau « /marine current ». Une seule source
    /// marine par port : plus de double round-trip ni de cache parallèle qui peut diverger.
    func fetchForPort(_ port: Port) async {
        let hourly = await fetchHourlyForecast(for: port)
        guard !hourly.isEmpty else { return }
        let now = Date()
        if let closest = hourly.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }) {
            currentConditions = MarineConditions(from: closest)
        }
    }

    // MARK: - Hourly Forecast (pour le planificateur)

    private var forecastCache: [String: (forecasts: [HourlyForecast], timestamp: Date)] = [:]
    private let forecastCacheExpiration: TimeInterval = 3600 // 1h

    // Plafond d'entrées : sans éviction, ces deux caches — sur un singleton à vie process —
    // grossissent indéfiniment (chaque port/spot custom est une clé). forecastCache pèse lourd
    // (jusqu'à ~15 j × 24 h par entrée). On évince les plus anciennes au-delà du plafond.
    private let maxCacheEntries = 60
    private func trimForecastCache() {
        guard forecastCache.count > maxCacheEntries else { return }
        let overflow = forecastCache.count - maxCacheEntries
        for k in forecastCache.sorted(by: { $0.value.timestamp < $1.value.timestamp }).prefix(overflow).map(\.key) {
            forecastCache.removeValue(forKey: k)
        }
    }

    /// Prévisions en CACHE pour un port (lecture synchrone, sans réseau). nil si rien de frais.
    /// Sert au widget vent : repli sur le vent prévu quand aucune balise temps réel n'est dispo.
    func cachedForecast(for port: Port) -> [HourlyForecast]? {
        cachedForecast(latitude: port.latitude, longitude: port.longitude)
    }

    /// Prévisions en CACHE à une COORDONNÉE (lecture synchrone, sans réseau). nil si rien de frais.
    /// Sert à la CARTE surf : on colore une pastille de spot SEULEMENT si sa prévision est déjà en
    /// cache (jamais de fetch déclenché au pan → offline-safe, pas de fan-out réseau).
    func cachedForecast(latitude: Double, longitude: Double) -> [HourlyForecast]? {
        let cacheKey = "\(String(format: "%.2f", latitude)),\(String(format: "%.2f", longitude))"
        guard let c = forecastCache[cacheKey],
              Date().timeIntervalSince(c.timestamp) < forecastCacheExpiration else { return nil }
        return c.forecasts
    }

    /// Récupère les prévisions horaires vent + vagues pour un port sur les 14 prochains jours
    // ⚠️ NE PAS DÉCALER LE POINT D'ÉCHANTILLONNAGE VERS LE LARGE. Essayé, mesuré, RETIRÉ.
    //
    // Le raisonnement semblait bon : AROME travaille à 1,3 km, la maille qui contient une plage
    // à dune large est classée TERRE, et sa rugosité divise le vent par deux (Lacanau : 9,3 nds
    // au point du spot, 18,1 nds à 2 km au large). « Personne ne navigue derrière la dune. »
    //
    // Sauf que la maille terre décrit assez bien la zone où l'on navigue RÉELLEMENT — les
    // premières centaines de mètres, encore sous l'influence de la côte — tandis que 2 km au
    // large, c'est du vent de pleine mer. Avec le décalage, l'app annonçait 8 à 9 nds de plus
    // que tous les autres sites de prévision kite. Un écart entre deux spots se discute ;
    // être systématiquement au-dessus de tout le monde est immédiatement vérifiable, et faux.
    //
    // La grille de 1,3 km ne laisse d'ailleurs pas de milieu : le point est dans la maille
    // terre ou dans la maille mer, il n'y a pas de position intermédiaire à trouver.
    //
    // On interroge donc le point du spot, tel qu'il est. Si un spot est manifestement mal placé,
    // c'est SA COORDONNÉE qu'il faut corriger dans le catalogue — pas la façon de l'interroger.
    func fetchHourlyForecast(for port: Port) async -> [HourlyForecast] {
        await fetchHourlyForecast(latitude: port.latitude, longitude: port.longitude)
    }

    /// Pré-charge (BORNÉ) la prévision d'une coordonnée si le cache est absent/périmé ; no-op si frais.
    /// Sert à remplir les labels orange des spots de surf de la carte SANS fan-out réseau : l'appelant
    /// (Coordinator carte) cap le nombre + débounce. Offline-safe (échec silencieux → label « — »).
    func prefetchForecastIfStale(latitude: Double, longitude: Double) async {
        if cachedForecast(latitude: latitude, longitude: longitude) != nil { return }
        _ = await fetchHourlyForecast(latitude: latitude, longitude: longitude)
    }

    /// Cœur par COORDONNÉE (le `for port:` ci-dessus délègue ici). N'utilise que lat/lon → réutilisable
    /// pour le prefetch des spots de surf (clé de cache identique « %.2f,%.2f »).
    func fetchHourlyForecast(latitude: Double, longitude: Double) async -> [HourlyForecast] {
        let cacheKey = "\(String(format: "%.2f", latitude)),\(String(format: "%.2f", longitude))"

        if let cached = forecastCache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < forecastCacheExpiration {
            return cached.forecasts
        }

        async let windData = fetchWindEnsemble(latitude: latitude, longitude: longitude)
        async let extrasData = fetchWeatherExtras(latitude: latitude, longitude: longitude)
        async let marineData = fetchMarineHourly(latitude: latitude, longitude: longitude)

        let (wind, extras, marine) = await (windData, extrasData, marineData)

        // Merge wind-ensemble + extras + marine by matching timestamps
        var forecasts: [HourlyForecast] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Fallback formatter for Open-Meteo (yyyy-MM-dd'T'HH:mm format)
        let simpleFormatter = DateFormatter()
        simpleFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        simpleFormatter.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current

        func parseDate(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? simpleFormatter.date(from: str)
        }

        if let h = wind?.hourly, let times = h.time {

            // Marine lookup par heure : timeString → index (on lit ensuite chaque champ par
            // index, comme extrasLookup ci-dessous). Évite un tuple à 16 champs et porte sans
            // perte les directions + partitions + SST nouvellement requêtées.
            var marineLookup: [String: Int] = [:]
            if let mTimes = marine?.hourly?.time {
                for i in 0..<mTimes.count { marineLookup[mTimes[i]] = i }
            }
            let mHourly = marine?.hourly

            // Extras lookup par heure (température, code météo, etc. — modèle best_match)
            var extrasLookup: [String: Int] = [:]   // timeString → index
            if let eTimes = extras?.hourly?.time {
                for i in 0..<eTimes.count { extrasLookup[eTimes[i]] = i }
            }
            let eHourly = extras?.hourly

            for i in 0..<times.count {
                guard let date = parseDate(times[i]) else { continue }

                // ORDRE = PRIORITÉ (cf. WindEnsemble.modelPriority) : le premier qui répond
                // donne la valeur. Les suivants ne servent qu'à mesurer la confiance.
                let readings: [WindModelReading] = [
                    WindModelReading(speed: h.wind_speed_10m_meteofrance_seamless?[safe: i].flatMap { $0 },
                                     gust: h.wind_gusts_10m_meteofrance_seamless?[safe: i].flatMap { $0 },
                                     dir: h.wind_direction_10m_meteofrance_seamless?[safe: i].flatMap { $0 }),
                    WindModelReading(speed: h.wind_speed_10m_icon_seamless?[safe: i].flatMap { $0 },
                                     gust: h.wind_gusts_10m_icon_seamless?[safe: i].flatMap { $0 },
                                     dir: h.wind_direction_10m_icon_seamless?[safe: i].flatMap { $0 }),
                    WindModelReading(speed: h.wind_speed_10m_gfs_seamless?[safe: i].flatMap { $0 },
                                     gust: h.wind_gusts_10m_gfs_seamless?[safe: i].flatMap { $0 },
                                     dir: h.wind_direction_10m_gfs_seamless?[safe: i].flatMap { $0 }),
                ]
                guard let blended = WindEnsemble.blend(readings) else { continue }

                let mi = marineLookup[times[i]]
                let ei = extrasLookup[times[i]]
                // Helper local : lit un champ marine `[Double?]?` à l'index de l'heure courante.
                func m(_ arr: [Double?]?) -> Double? { mi.flatMap { arr?[safe: $0].flatMap { $0 } } }

                forecasts.append(HourlyForecast(
                    time: date,
                    windSpeedKmh: blended.speed,
                    windGustKmh: blended.gust,
                    windDirection: blended.dir,
                    temperature: ei.flatMap { eHourly?.temperature_2m?[safe: $0].flatMap { $0 } },
                    weatherCode: ei.flatMap { eHourly?.weather_code?[safe: $0].flatMap { $0 } },
                    waveHeight: m(mHourly?.wave_height),
                    wavePeriod: m(mHourly?.wave_period),
                    swellHeight: m(mHourly?.swell_wave_height),
                    swellPeriod: m(mHourly?.swell_wave_period),
                    waveDirection: m(mHourly?.wave_direction),
                    swellDirection: m(mHourly?.swell_wave_direction),
                    swellPeakPeriod: m(mHourly?.swell_wave_peak_period),
                    windWaveHeight: m(mHourly?.wind_wave_height),
                    secondarySwellHeight: m(mHourly?.secondary_swell_wave_height),
                    secondarySwellPeriod: m(mHourly?.secondary_swell_wave_period),
                    secondarySwellDirection: m(mHourly?.secondary_swell_wave_direction),
                    tertiarySwellHeight: m(mHourly?.tertiary_swell_wave_height),
                    tertiarySwellPeriod: m(mHourly?.tertiary_swell_wave_period),
                    tertiarySwellDirection: m(mHourly?.tertiary_swell_wave_direction),
                    waterTemperature: m(mHourly?.sea_surface_temperature),
                    humidity: ei.flatMap { eHourly?.relative_humidity_2m?[safe: $0].flatMap { $0 } },
                    pressure: ei.flatMap { eHourly?.pressure_msl?[safe: $0].flatMap { $0 } },
                    uvIndex: ei.flatMap { eHourly?.uv_index?[safe: $0].flatMap { $0 } },
                    precipitationProbability: ei.flatMap { eHourly?.precipitation_probability?[safe: $0].flatMap { $0 } },
                    windConfidence: blended.confidence
                ))
            }
        }

        // Ne cache QUE les résultats non vides : un échec réseau/parse ne doit pas
        // rester figé (vide) pendant 1 h et masquer le bandeau météo.
        if !forecasts.isEmpty {
            forecastCache[cacheKey] = (forecasts, Date())
            trimForecastCache()
        }
        return forecasts
    }

    /// Prévisions vent issues de 3 modèles (AROME + ICON + GFS) en une requête, pour
    /// combinaison d'ensemble. AROME (1,3 km) donne le vent côtier/thermique le plus fin.
    private func fetchWindEnsemble(latitude: Double, longitude: Double) async -> WindEnsembleResponse? {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            URLQueryItem(name: "models", value: "meteofrance_seamless,icon_seamless,gfs_seamless"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "forecast_days", value: "14"),
            URLQueryItem(name: "past_days", value: "1"),   // hier inclus → la courbe vent/rafale garde son historique après minuit

            URLQueryItem(name: "timezone", value: "Europe/Paris")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429 {
                    appLogger.warning("Open-Meteo: limite de débit (429) — réessai différé, cache conservé")
                } else {
                    appLogger.error("Open-Meteo: statut HTTP \(http.statusCode)")
                }
                return nil
            }
            return try JSONDecoder().decode(WindEnsembleResponse.self, from: data)
        } catch {
            // L'annulation (changement de port rapide) n'est pas une erreur.
            if (error as? URLError)?.code != .cancelled && !(error is CancellationError) {
                appLogger.error("Erreur ensemble vent: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Variables météo non ventées (température, code, humidité…) via best_match.
    private func fetchWeatherExtras(latitude: Double, longitude: Double) async -> WeatherExtrasResponse? {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,relative_humidity_2m,pressure_msl,uv_index,precipitation,precipitation_probability"),
            URLQueryItem(name: "forecast_days", value: "14"),
            URLQueryItem(name: "past_days", value: "1"),   // hier inclus → la courbe vent/rafale garde son historique après minuit

            URLQueryItem(name: "timezone", value: "Europe/Paris")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429 {
                    appLogger.warning("Open-Meteo: limite de débit (429) — réessai différé, cache conservé")
                } else {
                    appLogger.error("Open-Meteo: statut HTTP \(http.statusCode)")
                }
                return nil
            }
            return try JSONDecoder().decode(WeatherExtrasResponse.self, from: data)
        } catch {
            if (error as? URLError)?.code != .cancelled && !(error is CancellationError) {
                appLogger.error("Erreur extras météo: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Extrema du niveau d'eau (recalage fin des prédictions harmoniques)

    private struct SeaLevelResponse: Codable {
        let hourly: H?
        struct H: Codable {
            let time: [String]?
            let sea_level_height_msl: [Double?]?
        }
    }

    /// Extrema (PM/BM) du niveau d'eau modélisé par Open-Meteo sur ~3 jours, affinés
    /// par interpolation parabolique. Sert d'arbitre temporel pour le recalage fin
    /// des ports rattachés loin de leur station TICON.
    func fetchSeaLevelExtrema(latitude: Double, longitude: Double) async -> [(date: Date, isHigh: Bool, height: Double)] {
        guard var components = URLComponents(string: baseURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "sea_level_height_msl"),
            URLQueryItem(name: "forecast_days", value: "3"),
            URLQueryItem(name: "timezone", value: "UTC")
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let decoded = try? JSONDecoder().decode(SeaLevelResponse.self, from: data),
              let times = decoded.hourly?.time,
              let values = decoded.hourly?.sea_level_height_msl,
              times.count == values.count, times.count >= 3 else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")

        var extrema: [(date: Date, isHigh: Bool, height: Double)] = []
        for i in 1..<(values.count - 1) {
            guard let v0 = values[i - 1], let v1 = values[i], let v2 = values[i + 1],
                  let base = fmt.date(from: times[i]) else { continue }
            let isMax = v1 > v0 && v1 > v2
            let isMin = v1 < v0 && v1 < v2
            guard isMax || isMin else { continue }
            // Sommet de la parabole passant par les 3 points (date en heures + hauteur affinée).
            let denom = v0 - 2 * v1 + v2
            let dt = denom != 0 ? (v0 - v2) / (2 * denom) : 0
            let vertexH = denom != 0 ? v1 - (v0 - v2) * (v0 - v2) / (8 * denom) : v1
            extrema.append((base.addingTimeInterval(dt * 3600), isMax, vertexH))
        }
        return extrema
    }

    private func fetchMarineHourly(latitude: Double, longitude: Double) async -> MarineHourlyResponse? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "wave_height,wave_period,wave_direction,swell_wave_height,swell_wave_period,swell_wave_direction,swell_wave_peak_period,wind_wave_height,wind_wave_period,secondary_swell_wave_height,secondary_swell_wave_period,secondary_swell_wave_direction,tertiary_swell_wave_height,tertiary_swell_wave_period,tertiary_swell_wave_direction,sea_surface_temperature"),
            URLQueryItem(name: "forecast_days", value: "14"),
            URLQueryItem(name: "past_days", value: "1"),   // hier inclus → la courbe vent/rafale garde son historique après minuit

            URLQueryItem(name: "timezone", value: "Europe/Paris")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 429 {
                    appLogger.warning("Open-Meteo: limite de débit (429) — réessai différé, cache conservé")
                } else {
                    appLogger.error("Open-Meteo: statut HTTP \(http.statusCode)")
                }
                return nil
            }
            return try JSONDecoder().decode(MarineHourlyResponse.self, from: data)
        } catch {
            appLogger.error("Erreur prévisions marine: \(error.localizedDescription)")
            return nil
        }
    }

}

// MARK: - Safe Array Subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
