//
//  ActivityScoreService.swift
//  Tide It
//
//  Moteur de scoring des activités nautiques v2
//  Scoring pondéré à facteurs continus
//
//  Chaque activité est évaluée sur 5-6 facteurs indépendants.
//  Chaque facteur retourne un score entre 0 (mauvais) et 1 (optimal)
//  via des courbes mathématiques (cloche, plateau, rampe).
//  Le score final est la somme pondérée normalisée sur 100.
//
//  Sources méthodologiques :
//  - Théorie solunar (pêche : phases lunaires, changements de marée)
//  - Pratique des sports nautiques côtiers (surf, kite, baignade)
//  - Règle des douzièmes (courants et marnage)
//  - Échelle Beaufort simplifiée (impact vent)
//  - Échelle Douglas (état de la mer)
//

import Foundation
import SwiftUI
import WeatherKit

// MARK: - Activity Types

enum NauticalActivity: String, CaseIterable, Identifiable {
    case fishing = "Pêche"
    case surfing = "Surf"
    case kitesurfing = "Kitesurf"
    case kitefoil = "Kitefoil"
    case wingfoil = "Wing foil"
    case sailing = "Voile"
    case swimming = "Baignade"
    case boatLaunch = "Mise à l'eau"

    var id: String { rawValue }

    /// Foils (kitefoil/wing foil) : planent à moins de vent mais demandent PLUS d'eau.
    var isFoil: Bool { self == .kitefoil || self == .wingfoil }

    /// Nom affichable et localisé (la `rawValue` reste l'identité stable en français).
    var localizedName: String {
        switch self {
        case .fishing:     return String(localized: "Pêche")
        case .surfing:     return String(localized: "Surf")
        case .kitesurfing: return String(localized: "Kitesurf")
        case .kitefoil:    return String(localized: "Kitefoil")
        case .wingfoil:    return String(localized: "Wing foil")
        case .sailing:     return String(localized: "Voile")
        case .swimming:    return String(localized: "Baignade")
        case .boatLaunch:  return String(localized: "Mise à l'eau")
        }
    }

    var icon: String {
        switch self {
        case .fishing: return "fish.fill"
        case .surfing: return "figure.surfing"
        case .kitesurfing: return "wind"
        case .kitefoil: return "water.waves.and.arrow.up"
        case .wingfoil: return "figure.surfing"   // 'figure.wind.surfing' n'existe pas (symbole manquant)
        case .sailing: return "sailboat.fill"
        case .swimming: return "figure.pool.swim"
        case .boatLaunch: return "sailboat.fill"
        }
    }

    var color: Color {
        switch self {
        case .fishing: return .teal
        case .surfing: return .orange
        case .kitesurfing: return .mint
        case .kitefoil: return .green
        case .wingfoil: return .pink
        case .sailing: return .blue
        case .swimming: return .cyan
        case .boatLaunch: return .blue
        }
    }
}

// MARK: - Configuration d'un spot (réglée manuellement par l'utilisateur)

enum SpotType: String, Codable, CaseIterable {
    case basin   // bassin / plan d'eau abrité (a besoin de hauteur d'eau, houle ~nulle)
    case ocean   // océan / mer ouverte (pas de souci d'eau, mais houle = danger)

    var localizedName: String {
        switch self {
        case .basin: return String(localized: "Bassin / plan d'eau")
        case .ocean: return String(localized: "Océan / mer ouverte")
        }
    }
}

/// Paramètres terrain d'un spot, que seul l'utilisateur connaît. Pilotent le scoring.
struct SpotConfig: Codable, Equatable {
    /// Hauteur de marée MINIMALE (m) pour qu'il y ait assez d'eau (gate dur). nil = inconnu.
    var minWaterHeight: Double?
    /// Cap de la mer ouverte vu du spot (deg, 0=N, 90=E…). Sert à détecter le vent offshore.
    /// RÉUTILISÉ tel quel par le surf : c'est le « facing » du spot (offshore + exposition houle).
    var shoreOrientation: Double?
    var spotType: SpotType
    /// Vraie position GPS (surtout ports custom, qui héritent sinon des coords de référence).
    var customLatitude: Double?
    var customLongitude: Double?

    // — Terrain SURF (optionnel ; renseigné par l'utilisateur ou un seed). Tous Optionnels →
    //   le Codable SYNTHÉTISÉ décode les anciens blobs intacts (clés absentes = nil). Persiste,
    //   se synchronise iCloud et se PURGE déjà via SpotConfigStore.remove (purgePortState étape 4).
    //   Tout l'état surf par-spot vit ICI — aucun store parallèle (sinon fuite de purge).
    var breakType: BreakType?
    var bottomType: BottomType?
    /// Centre de l'ARC de directions de houle que le spot reçoit réellement (deg). Distinct du
    /// cap `shoreOrientation` : un spot peut être abrité du vent mais ne marcher que sur une
    /// houle étroite. nil = on retombe sur `shoreOrientation` pour l'exposition.
    var swellWindowCenterDeg: Double?
    var swellWindowSpreadDeg: Double?
    /// Phase de marée idéale du spot (gate par-spot, le différenciateur « surf lu via la marée »).
    var idealTideStage: TideStage?
    /// true = marée poussante (montante) préférée ; false = descendante ; nil = indifférent.
    var idealTideRising: Bool?
    /// Niveau minimal indicatif (0 débutant … 4 expert). nil = non renseigné.
    var skillFloor: Int?

    init(minWaterHeight: Double? = nil, shoreOrientation: Double? = nil,
         spotType: SpotType = .ocean, customLatitude: Double? = nil, customLongitude: Double? = nil,
         breakType: BreakType? = nil, bottomType: BottomType? = nil,
         swellWindowCenterDeg: Double? = nil, swellWindowSpreadDeg: Double? = nil,
         idealTideStage: TideStage? = nil, idealTideRising: Bool? = nil, skillFloor: Int? = nil) {
        self.minWaterHeight = minWaterHeight
        self.shoreOrientation = shoreOrientation
        self.spotType = spotType
        self.customLatitude = customLatitude
        self.customLongitude = customLongitude
        self.breakType = breakType
        self.bottomType = bottomType
        self.swellWindowCenterDeg = swellWindowCenterDeg
        self.swellWindowSpreadDeg = swellWindowSpreadDeg
        self.idealTideStage = idealTideStage
        self.idealTideRising = idealTideRising
        self.skillFloor = skillFloor
    }
}

/// Stockage des configs de spot par identifiant de port. Persisté + synchronisé iCloud.
@MainActor
final class SpotConfigStore: ObservableObject {
    static let shared = SpotConfigStore()
    static let storageKey = "spotConfigs"

    @Published private(set) var configs: [String: SpotConfig]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: SpotConfig].self, from: data) {
            configs = decoded
        } else {
            configs = [:]
        }
    }

    func config(for portId: String) -> SpotConfig? { configs[portId] }

    func set(_ config: SpotConfig, for portId: String) {
        configs[portId] = config
        persist()
    }

    func remove(for portId: String) {
        configs.removeValue(forKey: portId)
        persist()
    }

    func reloadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: SpotConfig].self, from: data),
           decoded != configs {
            configs = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            CloudSyncService.shared.saveSettings()
        }
    }
}

// MARK: - Préférences d'activités de l'utilisateur

/// Activités nautiques que pratique l'utilisateur (choisies à l'onboarding, modifiables
/// ensuite). Persistées localement et synchronisées via iCloud. Pilotent le moteur
/// « Sorties Parfaites » (quelles activités scanner pour proposer une fenêtre).
@MainActor
final class ActivityPreferences: ObservableObject {
    static let shared = ActivityPreferences()

    static let storageKey = "preferredActivities"

    @Published private(set) var selected: Set<NauticalActivity>

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        let restored = raw.compactMap(NauticalActivity.init(rawValue:))
        // Par défaut (jamais configuré) : toutes les activités → le moteur reste utile
        // même si l'utilisateur passe l'étape d'onboarding.
        selected = restored.isEmpty ? Set(NauticalActivity.allCases) : Set(restored)
    }

    func contains(_ activity: NauticalActivity) -> Bool { selected.contains(activity) }

    func toggle(_ activity: NauticalActivity) {
        if selected.contains(activity) {
            // Ne jamais tout retirer : au moins une activité reste active.
            if selected.count > 1 { selected.remove(activity) }
        } else {
            selected.insert(activity)
        }
        persist()
    }

    func set(_ activities: Set<NauticalActivity>) {
        selected = activities.isEmpty ? Set(NauticalActivity.allCases) : activities
        persist()
    }

    /// Recharge depuis UserDefaults (ex. après une synchro iCloud externe).
    func reloadFromDefaults() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        let restored = Set(raw.compactMap(NauticalActivity.init(rawValue:)))
        if !restored.isEmpty, restored != selected { selected = restored }
    }

    private func persist() {
        UserDefaults.standard.set(selected.map(\.rawValue), forKey: Self.storageKey)
        CloudSyncService.shared.saveSettings()
    }
}

// MARK: - Activity Score Model

struct ActivityScore: Identifiable {
    let id = UUID()
    let activity: NauticalActivity
    let score: Int            // 0-100
    let label: String         // "Excellent", "Bon", "Moyen", "Mauvais"
    let details: [String]     // Raisons du score, triées par impact
    let bestTimeToday: Date?  // Meilleur moment de la journée

    // Verdict TEMPS RÉEL (rempli par calculateScore) :
    /// Fiabilité 0-1 = accord des modèles d'ensemble (AROME/ICON/GFS). nil = inconnu.
    var confidence: Double? = nil
    /// Le score a-t-il intégré une mesure FRAÎCHE de la balise (vent réel) ?
    var usedObservedWind: Bool = false
    /// Vent réel mesuré (km/h) au moment du score, si une balise fraîche est dispo.
    var observedWindKmh: Double? = nil

    var color: Color {
        switch score {
        case 80...100: return .green
        case 60..<80: return .cyan
        case 40..<60: return .yellow
        case 20..<40: return .orange
        default: return .red
        }
    }

    var labelText: String {
        switch score {
        case 80...100: return "Excellent"
        case 60..<80: return "Bon"
        case 40..<60: return "Moyen"
        case 20..<40: return "Mauvais"
        default: return "Déconseillé"
        }
    }
}

// MARK: - Scoring Factor (internal)

/// Représente un facteur de scoring avec son poids et sa contribution
private struct ScoringFactor {
    let name: String       // Nom court (ex: "Marée", "Vent")
    let weight: Double     // Poids relatif (0-1), la somme des poids par activité ≈ 1.0
    let score: Double      // Score du facteur (0 = mauvais, 1 = optimal)
    let detail: String     // Explication lisible pour l'utilisateur
}

// MARK: - Activity Score Service

class ActivityScoreService {
    static let shared = ActivityScoreService()

    // MARK: - Unit Formatting (respect user preferences)

    /// Unité de vent choisie par l'utilisateur (km/h, kn, mph, m/s) — lue depuis UserDefaults.
    private var userWindUnit: WindSpeedUnit {
        WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
    }

    /// Système d'unités (métrique/impérial) choisi par l'utilisateur.
    private var userMeasureSystem: MeasureSystem {
        MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric
    }

    /// Formate une vitesse de vent (entrée: km/h) dans l'unité utilisateur. Ex: "15 kn", "27 km/h".
    fileprivate func fmtWind(_ kmh: Double) -> String {
        let unit = userWindUnit
        return "\(UnitFormatter.windSpeedInt(kmh, unit: unit)) \(unit.label)"
    }

    /// Formate une température (entrée: °C) dans le système utilisateur. Ex: "18°C", "64°F".
    fileprivate func fmtTemp(_ celsius: Double) -> String {
        UnitFormatter.temp(celsius, system: userMeasureSystem)
    }

    /// Formate une hauteur (entrée: m) dans le système utilisateur. Ex: "1.5 m", "4.9 ft".
    fileprivate func fmtHeight(_ meters: Double) -> String {
        UnitFormatter.height(meters, system: userMeasureSystem)
    }

    // MARK: - Scoring Curves

    /// Courbe en cloche (Gaussienne) — pic à `c`, retombe à ~0 à ±2w
    /// Usage : facteurs avec une valeur optimale précise (ex: mi-marée pour le surf)
    private static func bell(_ v: Double, c: Double, w: Double) -> Double {
        let t = (v - c) / w
        return exp(-2 * t * t)
    }

    /// Plateau — 1.0 entre lo et hi, retombe en gaussienne au-delà
    /// Usage : plage de valeurs idéales (ex: vent 15-25 km/h pour le kite)
    private static func plateau(_ v: Double, lo: Double, hi: Double, falloff: Double) -> Double {
        if v >= lo && v <= hi { return 1.0 }
        let d = v < lo ? (lo - v) / falloff : (v - hi) / falloff
        return exp(-2 * d * d)
    }

    /// Rampe montante — 0 à `lo`, 1 à `hi`, clampé
    /// Usage : plus c'est élevé mieux c'est (ex: période de houle)
    private static func ramp(_ v: Double, lo: Double, hi: Double) -> Double {
        max(0, min(1, (v - lo) / (hi - lo)))
    }

    /// Rampe descendante — 1 à `lo`, 0 à `hi`, clampé
    /// Usage : plus c'est bas mieux c'est (ex: hauteur vagues pour baignade)
    private static func rampDown(_ v: Double, lo: Double, hi: Double) -> Double {
        max(0, min(1, (hi - v) / (hi - lo)))
    }

    /// Combine les facteurs en score final (0-100) et détails triés par impact
    private static func combine(_ factors: [ScoringFactor]) -> (score: Int, details: [String]) {
        guard !factors.isEmpty else { return (50, ["Données insuffisantes"]) }

        let totalWeight = factors.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return (50, ["Données insuffisantes"]) }

        let raw = factors.reduce(0.0) { $0 + $1.weight * $1.score } / totalWeight
        let score = Int((raw * 100).rounded())

        // Trier par impact décroissant : poids × écart à la neutralité (0.5)
        let sorted = factors.sorted { $0.weight * abs($0.score - 0.5) > $1.weight * abs($1.score - 0.5) }
        let details = sorted.map { $0.detail }

        return (max(0, min(100, score)), details)
    }

    // MARK: - Lightweight Weather (for planner, avoids WeatherKit dependency)

    /// Simple weather data from Open-Meteo forecasts
    struct SimpleWeather {
        let windSpeedKmh: Double
        let windGustKmh: Double?
        let temperatureCelsius: Double?
        var windDirectionDeg: Double? = nil   // d'où vient le vent (météo)
    }

    /// Scoring with simple weather data (for planner multi-day forecasts)
    func calculateScore(
        for activity: NauticalActivity,
        tideData: [TideData],
        simpleWeather: SimpleWeather?,
        marineConditions: MarineConditions?,
        currentTime: Date,
        spot: SpotConfig? = nil
    ) -> ActivityScore {
        windOverride = simpleWeather.map { (speed: $0.windSpeedKmh, gust: $0.windGustKmh) }
        tempOverride = simpleWeather?.temperatureCelsius
        windDirOverride = simpleWeather?.windDirectionDeg
        let result = calculateScore(for: activity, tideData: tideData, weather: nil,
                                    marineConditions: marineConditions, currentTime: currentTime, spot: spot)
        windOverride = nil
        tempOverride = nil
        windDirOverride = nil
        return result
    }

    /// Reconstruit la série de prévisions en INJECTANT les relevés réels (balise vent + bouée houle)
    /// sur l'horizon IMMINENT (≈ maintenant → +2 h), poids = proximité-temporelle × confiance PAR CANAL.
    /// Hors horizon ou sans relevé : l'heure passe telle quelle. Base de l'affinage jour-J de la note.
    /// Horloge fournie (`now`) = temps courant de la courbe, pas l'heure murale (synchro de la rampe).
    func refinedForecasts(_ series: [HourlyForecast], observedWind: WindReading?,
                          buoyWave: (wave: WaveReading, distanceKm: Double)?, now: Date) -> [HourlyForecast] {
        guard observedWind != nil || buoyWave != nil else { return series }
        return series.map { f in
            let hoursFromNow = f.time.timeIntervalSince(now) / 3600
            guard hoursFromNow >= -0.5, hoursFromNow <= 2 else { return f }   // n'affine que maintenant → +2 h
            let closeness = max(0, min(1, 1 - hoursFromNow / 2))              // 1 maintenant, 0 à +2 h
            var out = f
            // VENT réel (balise) : gate âge ≤ 20 min, rampe 1 - âge/20 (mêmes conventions que Go %).
            if let w = observedWind {
                let age = Double(w.minutesOld(asOf: now))
                if age <= 20 {
                    let wWind = closeness * max(0, 1 - age / 20)
                    if wWind > 0 {
                        out = out.withWind(
                            speed: w.speedAvgKmh * wWind + f.windSpeedKmh * (1 - wWind),
                            gust: w.gustKmh ?? f.windGustKmh,
                            direction: wWind > 0.5 ? w.directionDegrees : f.windDirection)
                    }
                }
            }
            // HOULE réelle (bouée NDBC) : gate âge ≤ 60 min (publication horaire) + falloff distance.
            // windWaveHeight INCHANGÉE (Hs bouée = totale, pas une partition) → pureté honnête.
            if let b = buoyWave {
                let age = Double(b.wave.minutesOld(asOf: now))
                if age <= 60 {
                    let falloff = max(0, min(1, 1 - b.distanceKm / 140))
                    let wWave = closeness * max(0, 1 - age / 60) * falloff
                    if wWave > 0 {
                        let blendedH = b.wave.heightM * wWave + (f.swellHeight ?? f.waveHeight ?? b.wave.heightM) * (1 - wWave)
                        let blendedP: Double? = b.wave.periodS.map { bp in
                            bp * wWave + (f.swellPeriod ?? f.wavePeriod ?? bp) * (1 - wWave)
                        } ?? f.swellPeriod
                        out = out.withSwell(height: blendedH, period: blendedP, peak: blendedP,
                                            direction: b.wave.directionDegrees ?? f.swellDirection)
                    }
                }
            }
            return out
        }
    }

    /// Note de QUALITÉ de session SURF d'une fenêtre GO, 1–5 ★ (nil = données indisponibles → pas
    /// d'étoile). Mode AUTO uniquement (l'appelant garde l'étoile pour `setup.auto && sport.surf`).
    /// Conçu via recherche dédiée (réutilise le MÊME `scoreHour(.surf)` que le moteur GO → jamais en
    /// contradiction avec le badge/calendrier, + métriques surf natives). HONNÊTE : plafonds d'angle
    /// mort (sans orientation de spot → jamais 5★), caps oversized/flat/clapot, 5★ rare. Constantes
    /// nommées (recalibrables après logs réels). Notation ABSOLUE (indépendante de la sensibilité AUTO).
    func surfSessionStars(window: (start: Date, end: Date), forecasts series: [HourlyForecast],
                          tideData tide: [TideData], spot: SpotConfig?) -> Int? {
        let wBase = 0.62, wSpot = 0.38                       // mélange verdict app / qualité spot
        let peakBias = 0.6, meanBias = 0.4                   // cœur de session peak-biased
        let capOversized = 0.60, capFlat = 0.45              // régimes mal vus par le modèle large
        let capWindsea = 0.55, capLowEnergy = 0.45
        let capBlind = 0.78, capNoPurity = 0.85              // plafonds de confiance
        func soft(_ x: Double) -> Double { 0.4 + 0.6 * x }   // signal faible-mais-présent → dégradé, pas zéro

        let hrs = series.filter { $0.time >= window.start && $0.time < window.end }.sorted { $0.time < $1.time }
        guard !hrs.isEmpty else { return nil }

        var q: [Double] = []
        var anyMetric = false
        for f in hrs {
            let qh = Double(scoreHour(sport: .surf, at: f, tideData: tide, spot: spot)) / 100.0
            let trend = SurfMetrics.swellTrend(in: series, around: f.time, windowHours: 3)
            guard let m = SurfHourMetrics.make(from: f, spot: spot, trend: trend) else {
                q.append(qh)   // pas de métrique cette heure → base seule, jamais de qualité spot fabriquée
                continue
            }
            anyMetric = true
            let e = m.energyIndex / 100.0
            let spotQ = e * soft(m.shoreExposure ?? 0.6) * soft(m.windGrooming ?? 0.6) * soft(m.purity ?? 0.6)
            var v = wBase * qh + wSpot * spotQ
            v += (m.swellTrend == .building ? 0.05 : (m.swellTrend == .dropping ? -0.06 : 0.0))
            v = max(0, min(1, v))
            if m.breakingHeight.upperBound > 3.0 { v = min(v, capOversized) }   // trop gros
            if m.dominantSwellHeight < 0.4       { v = min(v, capFlat) }        // quasi flat
            if let p = m.purity, p < 0.45        { v = min(v, capWindsea) }     // mer du vent domine
            if m.energyIndex < 18                { v = min(v, capLowEnergy) }   // énergie sous le seuil « propre »
            let directional = (m.shoreExposure != nil ? 1 : 0) + (m.windGrooming != nil ? 1 : 0)
            if directional < 2                   { v = min(v, capBlind) }       // spot sans orientation → jamais 5★
            if m.purity == nil                   { v = min(v, capNoPurity) }    // pureté inconnue → plafond
            q.append(v)
        }
        guard anyMetric else { return nil }   // aucune métrique sur toute la fenêtre → indisponible

        // Cœur contigu (~2 h) qui maximise la moyenne ; score peak-biased.
        let L = min(q.count, 2)
        var bestMean = -1.0, bestPeak = 0.0
        for i in 0...(q.count - L) {
            let run = Array(q[i..<(i + L)])
            let mean = run.reduce(0, +) / Double(L)
            if mean > bestMean { bestMean = mean; bestPeak = run.max() ?? mean }
        }
        var ws = peakBias * bestPeak + meanBias * bestMean
        if hrs.count == 1 { ws *= 0.92 }                     // une seule heure GO = moins fiable
        ws = max(0, min(1, ws))

        if ws >= 0.82 { return 5 }
        if ws >= 0.66 { return 4 }
        if ws >= 0.50 { return 3 }
        if ws >= 0.34 { return 2 }
        return 1
    }

    /// Note de session 1–5 ★ pour N'IMPORTE QUEL sport — MÊME visuel, moteur DIFFÉRENT selon le sport.
    /// Surf → moteur houle (surfSessionStars) ; vent/kite/wing/voile → moteur vent (windSessionStars).
    /// nil = données indisponibles → pas d'étoile.
    func sessionStars(sport: WindSport, window: (start: Date, end: Date), forecasts series: [HourlyForecast],
                      tideData tide: [TideData], spot: SpotConfig?) -> Int? {
        if sport.isSurf {
            return surfSessionStars(window: window, forecasts: series, tideData: tide, spot: spot)
        }
        return windSessionStars(sport: sport, window: window, forecasts: series, tideData: tide, spot: spot)
    }

    /// Note de session des sports de VENT (kite/wing/voile) — agrège le score AUTO (`scoreHour`, qui
    /// proxie voile→kite via nauticalActivity) sur la fenêtre. N'appelle JAMAIS SurfHourMetrics.make
    /// (nil hors mer). Cœur contigu ~2 h peak-biased (même forme que le surf), mais seuils PROPRES au
    /// vent — provisoires, à recalibrer après logs (la distribution du score vent ≠ celle du surf).
    func windSessionStars(sport: WindSport, window: (start: Date, end: Date), forecasts series: [HourlyForecast],
                          tideData tide: [TideData], spot: SpotConfig?) -> Int? {
        let cut5 = 0.85, cut4 = 0.72, cut3 = 0.60, cut2 = 0.48
        let hrs = series.filter { $0.time >= window.start && $0.time < window.end }.sorted { $0.time < $1.time }
        guard !hrs.isEmpty else { return nil }
        let q = hrs.map { Double(scoreHour(sport: sport, at: $0, tideData: tide, spot: spot)) / 100.0 }
        let L = min(q.count, 2)
        var bestMean = -1.0, bestPeak = 0.0
        for i in 0...(q.count - L) {
            let run = Array(q[i..<(i + L)])
            let mean = run.reduce(0, +) / Double(L)
            if mean > bestMean { bestMean = mean; bestPeak = run.max() ?? mean }
        }
        var ws = 0.6 * bestPeak + 0.4 * bestMean
        if hrs.count == 1 { ws *= 0.92 }
        ws = max(0, min(1, ws))
        if ws >= cut5 { return 5 }
        if ws >= cut4 { return 4 }
        if ws >= cut3 { return 3 }
        if ws >= cut2 { return 2 }
        return 1
    }

    /// Note 0–100 d'un SPORT pour une heure de prévision (mode AUTO = note ≥ seuil). Réutilise le
    /// scoring planner : overrides vent/température/direction + conditions marines synthétiques
    /// dérivées de la prévision. Pure lecture, pas d'I/O.
    func scoreHour(sport: WindSport, at f: HourlyForecast, tideData: [TideData], spot: SpotConfig?,
                   riderLevel: RiderLevel? = nil) -> Int {
        currentRiderLevel = riderLevel
        defer { currentRiderLevel = nil }
        let sw = SimpleWeather(windSpeedKmh: f.windSpeedKmh, windGustKmh: f.windGustKmh,
                               temperatureCelsius: f.temperature, windDirectionDeg: f.windDirection)
        let marine = MarineConditions(from: f)
        return calculateScore(for: sport.nauticalActivity, tideData: tideData, simpleWeather: sw,
                              marineConditions: marine, currentTime: f.time, spot: spot).score
    }

    // Overrides used by planner path — avoids duplicating all scoring functions
    private(set) var windOverride: (speed: Double, gust: Double?)?
    private(set) var tempOverride: Double?
    private(set) var windDirOverride: Double?
    /// Config du spot en cours d'évaluation (réglée par l'utilisateur).
    private(set) var currentSpot: SpotConfig?
    /// Niveau du rider en cours d'évaluation (mode AUTO) → plafonds de confort (vent/houle) dans
    /// le scoring. nil = pas de niveau (chemin live/legacy) → bornes par défaut.
    private(set) var currentRiderLevel: RiderLevel?

    /// Mesure FRAÎCHE de la balise injectée dans le scoring TEMPS RÉEL (chemin live seulement —
    /// le planner multi-jours passe par `windOverride` et n'est jamais concerné).
    private(set) var observedWind: (speedKmh: Double, gustKmh: Double?, directionDeg: Double, ageMinutes: Int)?
    /// Confiance d'ensemble (0-1) de l'heure courante → estampillée sur le verdict.
    private(set) var currentWindConfidence: Double?
    /// Le dernier `resolvedWind` a-t-il réellement utilisé la balise (mesure fraîche) ?
    private(set) var lastResolveUsedObserved = false

    /// Âge max (min) d'une mesure balise pour entrer dans le scoring (au-delà → prévision seule).
    private static let observedMaxAgeMin = 20.0

    /// Returns wind speed in km/h. Chemin live : FUSION prévision + balise (pondérée par la
    /// fraîcheur de la mesure : 100 % balise à 0 min, 0 % à 20 min). Planner : override seul.
    func resolvedWind(from weather: CurrentWeather?) -> (speed: Double, gust: Double?)? {
        if let ov = windOverride { return ov }   // planner → prévision uniquement
        let forecast: (speed: Double, gust: Double?)? = weather.map {
            ($0.wind.speed.converted(to: .kilometersPerHour).value,
             $0.wind.gust?.converted(to: .kilometersPerHour).value)
        }
        if let obs = observedWind, obs.ageMinutes < Int(Self.observedMaxAgeMin) {
            lastResolveUsedObserved = true
            let wObs = max(0.0, 1.0 - Double(obs.ageMinutes) / Self.observedMaxAgeMin)  // 1→0
            let speed = forecast.map { obs.speedKmh * wObs + $0.speed * (1 - wObs) } ?? obs.speedKmh
            return (speed, obs.gustKmh ?? forecast?.gust)
        }
        lastResolveUsedObserved = false
        return forecast
    }

    /// Returns temperature in Celsius from either CurrentWeather or override
    func resolvedTemp(from weather: CurrentWeather?) -> Double? {
        if let ov = tempOverride { return ov }
        return weather?.temperature.converted(to: .celsius).value
    }

    /// Direction du vent (deg, d'où vient le vent). Balise fraîche prioritaire (chemin live).
    func resolvedWindDirection(from weather: CurrentWeather?) -> Double? {
        if let ov = windDirOverride { return ov }
        if let obs = observedWind, obs.ageMinutes < Int(Self.observedMaxAgeMin) { return obs.directionDeg }
        return weather?.wind.direction.converted(to: .degrees).value
    }

    /// Vent minimum du rider (km/h), lu depuis les réglages.
    private var riderMinWind: Double {
        let v = UserDefaults.standard.double(forKey: "riderMinWindKmh")
        return v > 0 ? v : 12
    }
    /// Vent MAX réglé par l'utilisateur (réglage existant, défaut 65) — borne haute du GO, cohérente
    /// avec le bandeau vent live. Le niveau du rider la resserre par MIN (jamais au-dessus de SON max).
    private var riderMaxWind: Double {
        let v = UserDefaults.standard.double(forKey: "riderMaxWindKmh")
        return v > 0 ? v : 65
    }

    /// Plafond de vent praticable : au-delà = tempête, on ne propose pas de sortie.
    static let windDangerCeilingKmh = 50.0
    /// Tolérance sous la limite rider : on accepte jusqu'à 20% en dessous.
    static let windToleranceFactor = 0.8

    /// Le vent est-il dans la plage PRATICABLE pour une activité ventée (kite/wing/foil) ?
    /// Rejette sous (limite rider − 20%) ou au-delà du plafond tempête. Logique pure, testable.
    /// L'epsilon rend la borne basse inclusive malgré l'imprécision flottante (ex. 12×0,8).
    nonisolated static func windPracticable(windKmh: Double, minWindKmh: Double) -> Bool {
        windKmh >= minWindKmh * windToleranceFactor - 0.001 && windKmh < windDangerCeilingKmh
    }

    // MARK: - Main Scoring

    func calculateScores(
        tideData: [TideData],
        weather: CurrentWeather?,
        marineConditions: MarineConditions?,
        currentTime: Date,
        observed: (speedKmh: Double, gustKmh: Double?, directionDeg: Double, ageMinutes: Int)? = nil,
        windConfidence: Double? = nil,
        spot: SpotConfig? = nil
    ) -> [ActivityScore] {
        // Injecte la balise + la confiance pour TOUTE la fournée, puis nettoie (le scoring
        // les lit via resolvedWind / currentWindConfidence). Chaque verdict est estampillé.
        observedWind = observed
        currentWindConfidence = windConfidence
        defer { observedWind = nil; currentWindConfidence = nil }
        let freshObserved = (observed.map { $0.ageMinutes < Int(Self.observedMaxAgeMin) }) ?? false
        return NauticalActivity.allCases.map { activity in
            var s = calculateScore(
                for: activity,
                tideData: tideData,
                weather: weather,
                marineConditions: marineConditions,
                currentTime: currentTime,
                spot: spot   // FIX : sans ça currentSpot=nil en live → toute la logique
                             // orientation/offshore/exposition/marée du spot était inerte (kite ET surf).
            )
            s.confidence = windConfidence
            s.usedObservedWind = freshObserved
            s.observedWindKmh = freshObserved ? observed?.speedKmh : nil
            return s
        }
    }

    func calculateScore(
        for activity: NauticalActivity,
        tideData: [TideData],
        weather: CurrentWeather?,
        marineConditions: MarineConditions?,
        currentTime: Date,
        spot: SpotConfig? = nil
    ) -> ActivityScore {
        currentSpot = spot
        defer { currentSpot = nil }
        switch activity {
        case .fishing:
            return fishingScore(tideData: tideData, weather: weather, marine: marineConditions, currentTime: currentTime)
        case .surfing:
            return surfingScore(tideData: tideData, weather: weather, marine: marineConditions, currentTime: currentTime)
        case .kitesurfing, .kitefoil, .wingfoil, .sailing:
            return kiteWingScore(for: activity, tideData: tideData, weather: weather, marine: marineConditions, currentTime: currentTime)
        case .swimming:
            return swimmingScore(tideData: tideData, weather: weather, marine: marineConditions, currentTime: currentTime)
        case .boatLaunch:
            return boatLaunchScore(tideData: tideData, weather: weather, marine: marineConditions, currentTime: currentTime)
        }
    }

    // MARK: - Pêche
    //
    // Théorie solunar : l'activité des poissons est maximale autour des changements
    // de marée (étales), durant les nouvelles et pleines lunes, et à l'aube/crépuscule.
    // Le coefficient idéal (65-95) crée du mouvement d'eau sans courants extrêmes.
    // Le vent faible garde la surface calme pour la ligne et la visibilité.

    private func fishingScore(
        tideData: [TideData],
        weather: CurrentWeather?,
        marine: MarineConditions?,
        currentTime: Date
    ) -> ActivityScore {
        var factors: [ScoringFactor] = []

        // — Phase de marée (30%) —
        // Les 2h autour des changements de marée sont les plus productifs.
        // percentToNextTide : 0 = vient de passer l'étale, 1 = approche la prochaine.
        if let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) {
            let p = state.percentToNextTide
            // Courbe en U : pics aux extrêmes (0 et 1 = étales)
            let phaseScore = max(Self.bell(p, c: 0, w: 0.22), Self.bell(p, c: 1, w: 0.22))
            // Floor 15% : mi-marée n'est pas complètement mort
            let adjusted = 0.15 + 0.85 * phaseScore
            // Bonus marée montante (amène la nourriture vers le bord)
            let riseBonus: Double = state.trend == .rising ? 0.08 : 0

            let desc: String
            if phaseScore > 0.7 {
                desc = "Changement de marée imminent : pic d'activité"
            } else if phaseScore > 0.3 {
                desc = "Marée en transition : activité modérée"
            } else {
                desc = "Mi-marée : activité réduite"
            }
            let suffix = state.trend == .rising ? " (montante)" : ""
            factors.append(ScoringFactor(name: "Marée", weight: 0.30, score: min(1, adjusted + riseBonus), detail: desc + suffix))
        }

        // — Vent (20%) —
        // Calme < 15 km/h idéal (surface propre, bonne visibilité).
        // 15-25 acceptable. > 35 = conditions très difficiles.
        if let windData = resolvedWind(from: weather) {
            let wind = windData.speed
            let s = Self.plateau(wind, lo: 0, hi: 15, falloff: 18)
            let desc: String
            if wind < 10 { desc = "Calme (\(fmtWind(wind))) : conditions idéales" }
            else if wind < 20 { desc = "Vent léger (\(fmtWind(wind)))" }
            else if wind < 35 { desc = "Vent modéré (\(fmtWind(wind))) : inconfortable" }
            else { desc = "Vent fort (\(fmtWind(wind))) : pêche difficile" }
            factors.append(ScoringFactor(name: "Vent", weight: 0.20, score: s, detail: desc))
        }

        // — Coefficient (15%) —
        // 65-95 : assez de mouvement d'eau pour l'alimentation des poissons
        // sans créer de courants extrêmes rendant la pêche impossible.
        if let coef = todayCoefficient(tideData: tideData, currentTime: currentTime) {
            let s = Self.plateau(Double(coef), lo: 65, hi: 95, falloff: 25)
            let desc: String
            if coef >= 65 && coef <= 95 { desc = "Coefficient idéal (\(coef))" }
            else if coef > 95 { desc = "Coefficient élevé (\(coef)) : courants forts" }
            else if coef >= 40 { desc = "Coefficient moyen (\(coef))" }
            else { desc = "Coefficient faible (\(coef)) : peu de mouvement" }
            factors.append(ScoringFactor(name: "Coefficient", weight: 0.15, score: s, detail: desc))
        }

        // — Horaire (15%) —
        // Aube (6h-8h) et crépuscule (17h-20h) : pics d'alimentation.
        // Les poissons se nourrissent davantage dans la pénombre.
        let hour = Double(Calendar.current.component(.hour, from: currentTime))
        let minute = Double(Calendar.current.component(.minute, from: currentTime))
        let hourDecimal = hour + minute / 60
        let timeScore = max(Self.bell(hourDecimal, c: 6.5, w: 2), Self.bell(hourDecimal, c: 18.5, w: 2))
        let timeAdjusted = 0.2 + 0.8 * timeScore // Floor 20%
        let timeDesc: String
        if timeScore > 0.6 { timeDesc = hourDecimal < 12 ? "Aube : créneau privilégié" : "Crépuscule : créneau privilégié" }
        else if hourDecimal >= 10 && hourDecimal <= 16 { timeDesc = "Milieu de journée : moins actif" }
        else { timeDesc = "Horaire correct" }
        factors.append(ScoringFactor(name: "Horaire", weight: 0.15, score: timeAdjusted, detail: timeDesc))

        // — Phase lunaire (10%) —
        // Théorie solunar : nouvelle lune et pleine lune = activité accrue.
        // L'attraction gravitationnelle maximale stimule le comportement alimentaire.
        let moonPhase = MoonPhaseHelper.phase(for: currentTime)
        let moonScore = max(
            Self.bell(moonPhase, c: 0, w: 0.10),
            Self.bell(moonPhase, c: 0.5, w: 0.10),
            Self.bell(moonPhase, c: 1.0, w: 0.10)
        )
        let moonAdjusted = 0.25 + 0.75 * moonScore // Floor 25%
        let moonDesc: String
        if moonPhase < 0.07 || moonPhase > 0.93 { moonDesc = "Nouvelle lune : activité accrue" }
        else if moonPhase > 0.43 && moonPhase < 0.57 { moonDesc = "Pleine lune : activité accrue" }
        else if moonPhase > 0.18 && moonPhase < 0.32 { moonDesc = "Premier quartier" }
        else if moonPhase > 0.68 && moonPhase < 0.82 { moonDesc = "Dernier quartier" }
        else { moonDesc = "Phase lunaire intermédiaire" }
        factors.append(ScoringFactor(name: "Lune", weight: 0.10, score: moonAdjusted, detail: moonDesc))

        // — État de la mer (10%) —
        // Mer calme = meilleur confort et meilleure visibilité pour la pêche côtière.
        if let marine = marine {
            let s = Self.rampDown(marine.waveHeight, lo: 0.3, hi: 2.5)
            let desc: String
            if marine.waveHeight < 0.5 { desc = "Mer calme : idéal" }
            else if marine.waveHeight < 1.5 { desc = "Mer peu agitée (\(fmtHeight(marine.waveHeight)))" }
            else { desc = "Mer agitée (\(fmtHeight(marine.waveHeight))) : inconfortable" }
            factors.append(ScoringFactor(name: "Mer", weight: 0.10, score: s, detail: desc))
        }

        let (score, details) = Self.combine(factors)
        let bestTime = tideData.first { $0.date > currentTime }?.date

        return ActivityScore(activity: .fishing, score: score, label: "", details: details, bestTimeToday: bestTime)
    }

    // MARK: - Surf
    //
    // Le surf nécessite des vagues de qualité (0.8-2.0m, période > 8s),
    // une surface propre (vent faible), et un état de marée favorable
    // (mi-marée montante pour la plupart des spots).
    // La houle longue période (swell) produit des vagues mieux formées
    // que le clapot de vent (wind waves).

    private func surfingScore(
        tideData: [TideData],
        weather: CurrentWeather?,
        marine: MarineConditions?,
        currentTime: Date
    ) -> ActivityScore {
        // HONNÊTETÉ : la houle vient d'un modèle LARGE (~25 km, offshore). On lit l'état de la
        // houle au large « à travers » le spot (cap + marée) — ce n'est JAMAIS une lecture
        // spot-grade du déferlement. La copy évite tout superlatif ("idéales"/"propre").
        let spot = currentSpot
        var factors: [ScoringFactor] = []

        // — Houle : énergie de la houle DOMINANTE (28%) —
        // On note la rideabilité (plateau sur la hauteur) et on DÉCRIT via la hauteur de
        // déferlement estimée en INTERVALLE (genou…overhead) + la taille/période au large.
        if let marine = marine {
            let h = marine.waveHeight
            let swH = (marine.swellHeight ?? h)
            let swP = marine.swellPeriod ?? marine.wavePeriod
            // Sweet spot rideable CALÉ SUR LE NIVEAU : un débutant note haut le petit/propre et
            // chute vite au-delà de son plafond ; un expert garde un large plateau. nil = défaut.
            let hiCap = currentRiderLevel.map { $0.surfMaxSwellM ?? 4.0 } ?? 2.5
            let loCap = (currentRiderLevel == .debutant) ? 0.5 : 0.8
            let s = Self.plateau(h, lo: loCap, hi: hiCap, falloff: 1.2)
            let breaking = SurfMetrics.breakingHeightRange(height: swH, period: swP)
            let bucket = SurfHeightBucket.bucket(forMeters: (breaking.lowerBound + breaking.upperBound) / 2)
            let desc: String
            if h < 0.3 { desc = "Flat (\(fmtHeight(h)))" }
            else if h < 0.8 { desc = "Petite houle (\(fmtHeight(h))) — déferlement ~\(bucket.localizedName.lowercased())" }
            else if h <= 2.5 { desc = "Houle \(fmtHeight(swH)) / \(Int(swP))s — déferlement ~\(bucket.localizedName.lowercased())" }
            else if h <= 3.5 { desc = "Grosse houle (\(fmtHeight(h))) : niveau requis" }
            else { desc = "Houle puissante (\(fmtHeight(h))) : engagé" }
            factors.append(ScoringFactor(name: "Houle", weight: 0.28, score: s, detail: desc))

            // — Période (14%) — longue période = houle organisée. MarineConditions ne porte
            //   que la période MOYENNE (pas le pic) → on l'annonce comme « moyenne ».
            let period = marine.swellPeriod ?? marine.wavePeriod
            let pScore = Self.ramp(period, lo: 5, hi: 13)
            let pDesc: String
            if period >= 10 { pDesc = "Longue période moyenne (\(Int(period))s) : houle organisée" }
            else if period >= 7 { pDesc = "Période moyenne (\(Int(period))s)" }
            else { pDesc = "Courte période (\(Int(period))s) : clapot" }
            factors.append(ScoringFactor(name: "Période", weight: 0.14, score: pScore, detail: pDesc))

            // — Pureté (8%) — houle / (houle + mer du vent) : plus la houle domine, plus c'est propre.
            if let purity = SurfMetrics.purity(swellHeight: marine.swellHeight, windWaveHeight: marine.windWaveHeight) {
                let desc = purity > 0.6 ? "Houle dominante : vagues formées" : "Mer du vent présente : surface hachée"
                factors.append(ScoringFactor(name: "Pureté", weight: 0.08, score: purity, detail: desc))
            }

            // — Exposition au cap du spot (12%) — la houle est-elle pointée vers le spot ?
            //   N'apparaît que si le spot a une orientation renseignée.
            if let exposure = SurfMetrics.shoreExposure(swellDirection: marine.swellDirection,
                                                        shoreOrientation: spot?.shoreOrientation) {
                let dirName = marine.waveDirectionName
                let desc: String
                if exposure > 0.7 { desc = "Houle de \(dirName) bien exposée au spot" }
                else if exposure > 0.3 { desc = "Houle de \(dirName) partiellement exposée" }
                else { desc = "Houle de \(dirName) mal orientée (spot à l'abri)" }
                factors.append(ScoringFactor(name: "Exposition", weight: 0.12, score: exposure, detail: desc))
            }
        } else {
            factors.append(ScoringFactor(name: "Houle", weight: 0.28, score: 0.3, detail: "Données houle indisponibles"))
        }

        // — État de marée (14%) — gate par-spot si l'utilisateur a renseigné la phase idéale,
        //   sinon repli sur la mi-marée (formation optimale). C'est « le surf lu via la marée ».
        if let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) {
            let p = state.percentToNextTide
            var s: Double
            var desc: String
            if let ideal = spot?.idealTideStage {
                // Phase courante approchée : bas (étale basse / ~mi descendante), haut, mi.
                let s0 = Self.surfTideStageScore(state: state, ideal: ideal, rising: spot?.idealTideRising)
                s = s0
                desc = s0 > 0.6 ? "\(ideal.localizedName) : fenêtre du spot"
                                : "Hors fenêtre \(ideal.localizedName.lowercased()) du spot"
            } else {
                s = Self.bell(p, c: 0.45, w: 0.30)
                if state.trend == .rising { s = min(1, s + 0.1) }
                if s > 0.7 { desc = "Mi-marée" + (state.trend == .rising ? " montante" : "") }
                else if state.trend == .highSlack || state.trend == .lowSlack { desc = "Étale" }
                else { desc = state.trend == .rising ? "Marée montante" : "Marée descendante" }
            }
            factors.append(ScoringFactor(name: "Marée", weight: 0.14, score: s, detail: desc))
        }

        // — Vent : grooming OFFSHORE (18%) — polarité INVERSE du kite : pour le surf l'offshore
        //   nettoie la face (bon). Si le spot a une orientation → grooming directionnel ;
        //   sinon repli « glassy » (seul le vent faible est noté favorable).
        if let windData = resolvedWind(from: weather) {
            let wind = windData.speed
            let windDir = resolvedWindDirection(from: weather)
            if let groom = SurfMetrics.windGrooming(windDirection: windDir, windSpeedKmh: wind,
                                                    shoreOrientation: spot?.shoreOrientation) {
                let offshoreDir = ((spot?.shoreOrientation ?? 0) + 180).truncatingRemainder(dividingBy: 360)
                let isOffshore = windDir.map { SurfMetrics.angularDistance($0, offshoreDir) < 50 } ?? false
                let desc: String
                if wind < 8 { desc = "Glassy (\(fmtWind(wind))) : surface lisse" }
                else if isOffshore && groom > 0.6 { desc = "Offshore (\(fmtWind(wind))) : face propre" }
                else if groom > 0.5 { desc = "Vent gérable (\(fmtWind(wind)))" }
                else { desc = "Onshore / vent fort (\(fmtWind(wind))) : surface dégradée" }
                factors.append(ScoringFactor(name: "Vent", weight: 0.18, score: groom, detail: desc))
            } else {
                // Cap inconnu : on ne peut pas juger l'offshore → seul le vent faible est favorable.
                let s = Self.plateau(wind, lo: 0, hi: 12, falloff: 15)
                let desc: String
                if wind < 8 { desc = "Glassy (\(fmtWind(wind))) : surface lisse" }
                else if wind < 18 { desc = "Vent léger (\(fmtWind(wind)))" }
                else if wind < 30 { desc = "Vent modéré (\(fmtWind(wind))) : surface dégradée" }
                else { desc = "Vent fort (\(fmtWind(wind))) : conditions hachées" }
                factors.append(ScoringFactor(name: "Vent", weight: 0.18, score: s, detail: desc))
            }
        }

        // — Coefficient (6%) — modère courants / dérive.
        if let coef = todayCoefficient(tideData: tideData, currentTime: currentTime) {
            let s = Self.plateau(Double(coef), lo: 50, hi: 85, falloff: 20)
            let desc: String
            if coef > 100 { desc = "Fort coefficient (\(coef)) : courants importants" }
            else if coef < 40 { desc = "Faible coefficient (\(coef)) : peu de courant" }
            else { desc = "Coefficient (\(coef))" }
            factors.append(ScoringFactor(name: "Coefficient", weight: 0.06, score: s, detail: desc))
        }

        let (score, details) = Self.combine(factors)
        return ActivityScore(activity: .surfing, score: score, label: "", details: details, bestTimeToday: nil)
    }

    /// Score de marée par-spot pour le surf : compare la phase courante à la phase idéale
    /// renseignée (bas / mi / haut), avec bonus si la marée pousse dans le sens préféré.
    private static func surfTideStageScore(state: TideCalculator.TideState, ideal: TideStage, rising: Bool?) -> Double {
        // `percentToNextTide` ∈ [0,1] = progression vers la PROCHAINE marée.
        let p = state.percentToNextTide
        // Phase actuelle approchée (0 = basse, 0.5 = mi, 1 = haute) à partir de la tendance.
        let level: Double
        switch state.trend {
        case .rising:    level = p                 // de bas (0) vers haut (1)
        case .falling:   level = 1 - p             // de haut (1) vers bas (0)
        case .highSlack: level = 1
        case .lowSlack:  level = 0
        }
        let target: Double = (ideal == .low) ? 0 : (ideal == .high ? 1 : 0.5)
        var s = max(0, 1 - abs(level - target) / 0.5)   // 1 pile sur la phase, 0 à ±0,5
        if let rising = rising {
            let goodDir = (rising && (state.trend == .rising || state.trend == .lowSlack))
                       || (!rising && (state.trend == .falling || state.trend == .highSlack))
            s = min(1, s + (goodDir ? 0.1 : -0.1))
        }
        return max(0, min(1, s))
    }

    // MARK: - Kitesurf
    //
    // Le kitesurf dépend principalement du vent (fenêtre 15-25 km/h idéale).
    // La régularité (écart vent moyen / rafales) est cruciale pour la sécurité.
    // Un plan d'eau calme est préféré, et la profondeur d'eau suffisante
    // est essentielle pour éviter les blessures sur les fonds.

    /// Distance angulaire circulaire (deg) entre deux caps, dans [0, 180].
    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        abs(((a - b + 540).truncatingRemainder(dividingBy: 360)) - 180)
    }

    /// Scoring commun Kite (twintip) / Kitefoil / Wing foil — tient compte de la config
    /// du spot (hauteur d'eau mini, orientation/offshore, type), du vent mini du rider,
    /// et des besoins propres aux foils (plus d'eau, moins de vent).
    private func kiteWingScore(
        for activity: NauticalActivity,
        tideData: [TideData],
        weather: CurrentWeather?,
        marine: MarineConditions?,
        currentTime: Date
    ) -> ActivityScore {
        var factors: [ScoringFactor] = []
        let spot = currentSpot
        let foil = activity.isFoil
        let minW = riderMinWind

        // Plancher + fenêtre idéale de vent selon l'engin (les foils planent plus tôt).
        let windFloor: Double, idealLo: Double, idealHi: Double
        switch activity {
        case .kitefoil: windFloor = max(6, minW - 5); idealLo = max(8, minW - 2); idealHi = idealLo + 12
        case .wingfoil: windFloor = max(7, minW - 2); idealLo = max(9, minW);     idealHi = idealLo + 12
        // Voile (dériveur/voilier) : avance dès la brise légère et tolère une PLAGE LARGE — plancher
        // bas, idéal large. Plafond haut géré par le niveau du rider (windCeiling) comme les autres.
        case .sailing:  windFloor = max(6, minW - 4); idealLo = max(10, minW - 2); idealHi = idealLo + 18
        default:        windFloor = minW;             idealLo = minW + 3;          idealHi = idealLo + 13   // twintip
        }

        // Plafond GO = le PLUS BAS entre le max-vent réglé par l'utilisateur (riderMaxWind, défaut 65,
        // = bandeau live) et le confort du NIVEAU (débutant protégé, intermédiaire = ancien 50 → pas de
        // régression). Sans niveau (chemin live) → riderMaxWind seul. Source de vérité unique = riderMax.
        let windCeiling = min(riderMaxWind, currentRiderLevel?.windCeilingKmh ?? riderMaxWind)
        let idealHiC = min(idealHi, windCeiling - 2)

        // Gate vent DUR : une sortie ventée n'a de sens QUE dans la plage praticable.
        // Le vent ne pesant que 32% du score, sans ce gate une fenêtre sans vent (ou en
        // pleine tempête) pourrait être « parfaite » grâce à l'eau/coef → faux positif.
        //  • sous (limite rider − 20%)  → pas assez de vent, on ne propose pas.
        //  • ≥ 50 km/h                  → tempête, dangereux/non pertinent.
        //  • aucune prévision de vent   → trop incertain pour une activité ventée.
        let windGateLo = minW * Self.windToleranceFactor   // tolérance 20% sous la limite fixée
        var hardCap: Int? = nil

        // — Vent (32%) — sous le plancher rider = 0 ; fenêtre idéale = 1 ; >45 = danger.
        if let windData = resolvedWind(from: weather) {
            let wind = windData.speed
            // Hors plage : sous le mini rider, OU au-delà du plafond du niveau → on ne propose pas.
            if wind < windGateLo - 0.001 || wind >= windCeiling { hardCap = 0 }
            let windScore: Double = {
                if wind < windFloor { return 0 }
                if wind < idealLo { return (wind - windFloor) / max(1, idealLo - windFloor) }
                if wind <= idealHiC { return 1 }
                if wind < windCeiling { return max(0.15, 1 - (wind - idealHiC) / max(1, windCeiling - idealHiC) * 0.85) }
                return 0.05
            }()
            let desc: String
            if wind < windGateLo { desc = "Pas assez de vent (\(fmtWind(wind)) < ton mini \(fmtWind(minW)))" }
            else if wind < windFloor { desc = "Sous ton vent mini (\(fmtWind(wind)))" }
            else if wind < idealLo { desc = "Vent limite (\(fmtWind(wind)))" }
            else if wind <= idealHi { desc = "Vent idéal (\(fmtWind(wind)))" }
            else if wind <= 45 { desc = "Vent fort (\(fmtWind(wind))) : petite aile" }
            else if wind < Self.windDangerCeilingKmh { desc = "Vent très fort (\(fmtWind(wind)))" }
            else { desc = "Vent dangereux (\(fmtWind(wind))) : tempête" }
            factors.append(ScoringFactor(name: "Vent", weight: 0.32, score: windScore, detail: desc))

            let gustDiff = (windData.gust ?? wind) - wind
            let gScore = Self.rampDown(gustDiff, lo: 5, hi: 25)
            let gDesc = gustDiff < 8 ? "Vent régulier" : (gustDiff < 18 ? "Rafales modérées (+\(fmtWind(gustDiff)))" : "Rafales fortes (+\(fmtWind(gustDiff))) : instable")
            factors.append(ScoringFactor(name: "Rafales", weight: 0.10, score: gScore, detail: gDesc))
        } else {
            hardCap = 0   // activité ventée sans prévision vent → on ne propose pas
            factors.append(ScoringFactor(name: "Vent", weight: 0.32, score: 0.2, detail: "Données vent indisponibles"))
        }

        // — Hauteur d'eau — gate DUR si le spot a un mini. Foil : besoin de + d'eau.
        let waterRequired = (spot?.minWaterHeight).map { $0 + (foil ? 0.6 : 0) } ?? (foil ? 1.3 : 0.8)
        if let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) {
            let h = state.currentHeight
            let s: Double
            if h < waterRequired {
                s = max(0, (h / waterRequired) * 0.25)
                let waterCap = max(0, Int((h / waterRequired) * 30))   // pas assez d'eau → score plafonné bas
                hardCap = min(hardCap ?? waterCap, waterCap)            // compose avec le gate vent (le + strict gagne)
            } else {
                let base = 0.65 + 0.35 * Self.ramp(h, lo: waterRequired, hi: waterRequired + 1.2)
                let trendBonus: Double = state.trend == .rising ? 0.08 : (state.trend == .lowSlack ? -0.1 : 0)
                s = max(0, min(1, base + trendBonus))
            }
            let desc: String
            if h < waterRequired { desc = "Pas assez d'eau (\(fmtHeight(h)) < \(fmtHeight(waterRequired)))" }
            else if h < waterRequired + 0.6 { desc = "Eau juste suffisante (\(fmtHeight(h)))" }
            else { desc = "Bon niveau d'eau (\(fmtHeight(h)))" }
            factors.append(ScoringFactor(name: "Hauteur d'eau", weight: foil ? 0.26 : 0.22, score: s, detail: desc))
        }

        // — Direction du vent (offshore = danger) — si le spot a une orientation.
        if let orient = spot?.shoreOrientation, let dir = resolvedWindDirection(from: weather) {
            let offshoreDir = (orient + 180).truncatingRemainder(dividingBy: 360)
            let offshoreness = max(0, 1 - Self.angularDistance(dir, offshoreDir) / 50)   // 1 = plein offshore
            let s = 1 - 0.9 * offshoreness
            let desc: String
            if offshoreness > 0.6 { desc = "Vent de terre (offshore) : DANGEREUX" }
            else if offshoreness > 0.25 { desc = "Vent tournant offshore : prudence" }
            else { desc = "Vent sûr (side/onshore)" }
            factors.append(ScoringFactor(name: "Direction vent", weight: 0.16, score: s, detail: desc))
        }

        // — Houle — danger sur spot océan ; ignorée sur bassin abrité.
        if spot?.spotType != .basin, let marine = marine {
            let s = Self.plateau(marine.waveHeight, lo: 0, hi: foil ? 0.8 : 1.2, falloff: 1.0)
            let desc: String
            if marine.waveHeight < 0.5 { desc = "Plan d'eau lisse" }
            else if marine.waveHeight < 1.5 { desc = "Houle modérée (\(fmtHeight(marine.waveHeight)))" }
            else if marine.waveHeight < 2.5 { desc = "Houle soutenue (\(fmtHeight(marine.waveHeight)))" }
            else { desc = "Forte houle (\(fmtHeight(marine.waveHeight))) : risqué" }
            factors.append(ScoringFactor(name: "Houle", weight: 0.12, score: s, detail: desc))
        }

        if let coef = todayCoefficient(tideData: tideData, currentTime: currentTime) {
            let s = Self.plateau(Double(coef), lo: 35, hi: 85, falloff: 20)
            factors.append(ScoringFactor(name: "Coefficient", weight: 0.06, score: s,
                                         detail: coef > 100 ? "Fort coef (\(coef)) : dérive" : "Coefficient (\(coef))"))
        }

        let temp = marine?.waterTemperature ?? resolvedTemp(from: weather)
        if let t = temp {
            let s = Self.plateau(t, lo: 14, hi: 24, falloff: 5)
            factors.append(ScoringFactor(name: "Température", weight: 0.05, score: s, detail: fmtTemp(t)))
        }

        var (score, details) = Self.combine(factors)
        if let cap = hardCap { score = min(score, cap) }   // gate dur : pénurie d'eau
        return ActivityScore(activity: activity, score: score, label: "", details: details, bestTimeToday: nil)
    }

    // MARK: - Baignade
    //
    // La sécurité prime : mer calme, peu de courant, eau tempérée.
    // L'étale (slack tide) est le moment le plus sûr (courant nul).
    // Le coefficient modère l'intensité des courants.
    // La température de l'eau (via MarineConditions) est utilisée en priorité.

    private func swimmingScore(
        tideData: [TideData],
        weather: CurrentWeather?,
        marine: MarineConditions?,
        currentTime: Date
    ) -> ActivityScore {
        var factors: [ScoringFactor] = []

        // — Vagues (25%) —
        // Mer calme (< 0.5m) = baignade sûre et agréable.
        // > 1.5m = déconseillé pour la baignade familiale.
        if let marine = marine {
            let h = marine.waveHeight
            let s = Self.rampDown(h, lo: 0.3, hi: 2.0)
            let desc: String
            if h < 0.3 { desc = "Mer d'huile : idéal" }
            else if h < 0.8 { desc = "Mer calme (\(fmtHeight(h)))" }
            else if h < 1.5 { desc = "Mer agitée (\(fmtHeight(h))) : vigilance" }
            else { desc = "Mer forte (\(fmtHeight(h))) : baignade déconseillée" }
            factors.append(ScoringFactor(name: "Mer", weight: 0.25, score: s, detail: desc))
        }

        // — Courants (25%) — Combinaison marée × coefficient
        // Étale (progress ~0 ou ~1) = courant nul = le plus sûr.
        // Mi-marée = courant maximum (règle des douzièmes : heures 3 et 4).
        // Le coefficient amplifie les courants : fort coef = courants plus intenses.
        if let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) {
            let p = state.percentToNextTide
            let slackScore = max(Self.bell(p, c: 0, w: 0.15), Self.bell(p, c: 1, w: 0.15))
            let baseCurrentScore = 0.2 + 0.8 * slackScore

            let coef = Double(todayCoefficient(tideData: tideData, currentTime: currentTime) ?? 70)
            let coefFactor = Self.rampDown(coef, lo: 40, hi: 110)
            let combined = baseCurrentScore * 0.6 + coefFactor * 0.4

            let desc: String
            if slackScore > 0.7 {
                desc = state.trend == .highSlack ? "Étale haute : pas de courant" : "Étale basse : courant nul"
            } else if p > 0.35 && p < 0.65 {
                desc = "Mi-marée : courants" + (coef > 80 ? " forts" : " modérés")
            } else {
                desc = state.trend == .rising ? "Marée montante : courants présents" : "Marée descendante : courants présents"
            }
            factors.append(ScoringFactor(name: "Courants", weight: 0.25, score: combined, detail: desc))
        }

        // — Température de l'eau (20%) —
        // Utilise waterTemperature de MarineConditions en priorité.
        // Sinon estimation conservatrice : air - 3°C.
        var waterTemp: Double?
        if let wt = marine?.waterTemperature {
            waterTemp = wt
        } else if let airT = resolvedTemp(from: weather) {
            waterTemp = airT - 3
        }
        if let wt = waterTemp {
            let s = Self.plateau(wt, lo: 17, hi: 23, falloff: 4)
            let desc: String
            if wt < 14 { desc = "Eau très froide (\(fmtTemp(wt))) : hypothermie risquée" }
            else if wt < 17 { desc = "Eau fraîche (\(fmtTemp(wt)))" }
            else if wt <= 23 { desc = "Eau agréable (\(fmtTemp(wt)))" }
            else { desc = "Eau chaude (\(fmtTemp(wt)))" }
            factors.append(ScoringFactor(name: "Eau", weight: 0.20, score: s, detail: desc))
        }

        // — Vent (15%) —
        // Le vent crée du clapot et du wind chill à la sortie de l'eau.
        if let windData = resolvedWind(from: weather) {
            let wind = windData.speed
            let s = Self.rampDown(wind, lo: 10, hi: 35)
            let desc: String
            if wind < 10 { desc = "Sans vent : agréable" }
            else if wind < 25 { desc = "Vent modéré (\(fmtWind(wind)))" }
            else { desc = "Vent fort (\(fmtWind(wind))) : inconfortable" }
            factors.append(ScoringFactor(name: "Vent", weight: 0.15, score: s, detail: desc))
        }

        // — Température air (15%) —
        // Confort sur la plage avant/après la baignade.
        if let airT = resolvedTemp(from: weather) {
            let s = Self.plateau(airT, lo: 20, hi: 30, falloff: 5)
            let desc: String
            if airT < 15 { desc = "Frais (\(fmtTemp(airT)))" }
            else if airT < 20 { desc = "Temps mitigé (\(fmtTemp(airT)))" }
            else if airT <= 30 { desc = "Beau temps (\(fmtTemp(airT)))" }
            else { desc = "Très chaud (\(fmtTemp(airT)))" }
            factors.append(ScoringFactor(name: "Air", weight: 0.15, score: s, detail: desc))
        }

        let (score, details) = Self.combine(factors)
        let bestTime = tideData.first { $0.date > currentTime && $0.isHighTide }?.date

        return ActivityScore(activity: .swimming, score: score, label: "", details: details, bestTimeToday: bestTime)
    }

    // MARK: - Mise à l'eau
    //
    // La mise à l'eau (cale, remorque) nécessite :
    // - Assez de profondeur pour la quille et la remorque (> 2.5m confortable)
    // - Conditions calmes pour manœuvrer (vent faible, mer calme)
    // - Courants modérés à la cale (coefficient pas trop fort)
    // - Marée montante préférable (sécurité au retour)

    private func boatLaunchScore(
        tideData: [TideData],
        weather: CurrentWeather?,
        marine: MarineConditions?,
        currentTime: Date
    ) -> ActivityScore {
        var factors: [ScoringFactor] = []

        // — Hauteur d'eau (30%) —
        // > 4m = confortable pour tout type de bateau.
        // 2.5-4m = correct. < 1.5m = impossible pour la plupart.
        if let state = TideCalculator.currentState(at: currentTime, sortedTides: tideData) {
            let h = state.currentHeight
            let s = Self.ramp(h, lo: 1.5, hi: 4.0)
            let desc: String
            if h < 1.5 { desc = "Niveau trop bas (\(fmtHeight(h))) : impossible" }
            else if h < 2.5 { desc = "Niveau juste (\(fmtHeight(h))) : attention" }
            else if h < 4.0 { desc = "Bon niveau d'eau (\(fmtHeight(h)))" }
            else { desc = "Niveau excellent (\(fmtHeight(h)))" }
            factors.append(ScoringFactor(name: "Niveau", weight: 0.30, score: s, detail: desc))

            // — Tendance marée (12%) —
            // Montante = le retour sera possible même si on reste longtemps.
            // Descendante = risque d'échouage si on s'absente trop longtemps.
            let trendScore: Double
            let trendDesc: String
            switch state.trend {
            case .rising:
                trendScore = 0.9; trendDesc = "Marée montante : sécurité au retour"
            case .highSlack:
                trendScore = 0.7; trendDesc = "Étale haute : bon créneau"
            case .falling:
                trendScore = 0.35; trendDesc = "Marée descendante : attention au retour"
            case .lowSlack:
                trendScore = 0.2; trendDesc = "Étale basse : attendre la montée"
            }
            factors.append(ScoringFactor(name: "Tendance", weight: 0.12, score: trendScore, detail: trendDesc))
        }

        // — Vent (23%) —
        // Calme = manœuvre aisée à la cale et en sortie de port.
        if let windData = resolvedWind(from: weather) {
            let wind = windData.speed
            let s = Self.plateau(wind, lo: 0, hi: 15, falloff: 15)
            let desc: String
            if wind < 10 { desc = "Calme (\(fmtWind(wind))) : manœuvre aisée" }
            else if wind < 20 { desc = "Vent léger (\(fmtWind(wind)))" }
            else if wind < 35 { desc = "Vent modéré (\(fmtWind(wind))) : manœuvre délicate" }
            else { desc = "Vent fort (\(fmtWind(wind))) : mise à l'eau risquée" }
            factors.append(ScoringFactor(name: "Vent", weight: 0.23, score: s, detail: desc))
        }

        // — Vagues (20%) —
        // La houle rend le lancement depuis la cale difficile et dangereux.
        if let marine = marine {
            let s = Self.rampDown(marine.waveHeight, lo: 0.3, hi: 2.0)
            let desc: String
            if marine.waveHeight < 0.5 { desc = "Mer calme : lancement facile" }
            else if marine.waveHeight < 1.0 { desc = "Légère houle (\(fmtHeight(marine.waveHeight)))" }
            else if marine.waveHeight < 1.5 { desc = "Houle modérée (\(fmtHeight(marine.waveHeight))) : délicat" }
            else { desc = "Mer forte (\(fmtHeight(marine.waveHeight))) : dangereux" }
            factors.append(ScoringFactor(name: "Mer", weight: 0.20, score: s, detail: desc))
        }

        // — Coefficient (15%) —
        // Forts coefficients = courants importants à la cale et dans les chenaux.
        if let coef = todayCoefficient(tideData: tideData, currentTime: currentTime) {
            let s = Self.plateau(Double(coef), lo: 40, hi: 85, falloff: 20)
            let desc: String
            if coef > 100 { desc = "Fort coefficient (\(coef)) : courants à la cale" }
            else if coef < 35 { desc = "Faible coefficient (\(coef)) : risque de fond bas" }
            else { desc = "Coefficient (\(coef))" }
            factors.append(ScoringFactor(name: "Coefficient", weight: 0.15, score: s, detail: desc))
        }

        let (score, details) = Self.combine(factors)
        let bestTime = tideData.first { $0.date > currentTime && $0.isHighTide }?.date

        return ActivityScore(activity: .boatLaunch, score: score, label: "", details: details, bestTimeToday: bestTime)
    }

    // MARK: - Helpers

    /// Récupère le premier coefficient du jour (associé aux pleines mers)
    private func todayCoefficient(tideData: [TideData], currentTime: Date) -> Int? {
        let calendar = Calendar.current
        let todayTides = tideData.filter { calendar.isDate($0.date, inSameDayAs: currentTime) }
        return todayTides.compactMap(\.coefficient).first
    }
}
