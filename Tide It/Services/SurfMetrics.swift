//
//  SurfMetrics.swift
//  Tide It
//
//  Structure de données du mode SURF : les métriques DÉRIVÉES (non fetchées) par heure,
//  calculées à partir des champs marine étendus de `HourlyForecast` + de la config du spot.
//
//  Honnêteté de marque ENCODÉE DANS LE TYPE :
//   - la hauteur de déferlement est un INTERVALLE (`ClosedRange`), jamais une valeur unique
//     « spot-grade » ;
//   - chaque métrique porte sa `provenance` + le nombre de partitions de houle utilisées ;
//   - la période sait si elle est un PIC (idéal surf) ou une MOYENNE (cas du backbone
//     public-domain) via `PeriodType`.
//
//  Tout est PUR (aucun fetch, aucun I/O) et offline-safe : ces fonctions transforment une
//  `HourlyForecast` déjà en cache. La houle provient d'un modèle large (~25 km, offshore) →
//  on ne prétend JAMAIS à une résolution de spot. L'affichage (TodayView / fenêtres GO) est
//  branché plus tard ; ce fichier ne fait QUE produire la donnée.
//

import Foundation

// MARK: - Terrain du spot (vocabulaire surf)

/// Type de déferlement d'un spot — ce que seul l'utilisateur (ou le seed) connaît.
enum BreakType: String, Codable, CaseIterable, Identifiable {
    case beach   // beach break (fond de sable)
    case reef    // reef break (récif)
    case point   // point break (pointe)
    case jetty   // digue / embouchure

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .beach: return String(localized: "Beach break")
        case .reef:  return String(localized: "Reef break")
        case .point: return String(localized: "Point break")
        case .jetty: return String(localized: "Digue / embouchure")
        }
    }
}

/// Nature du fond — influence le danger et la qualité de déferlement.
enum BottomType: String, Codable, CaseIterable, Identifiable {
    case sand, reef, rock, mixed

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .sand:  return String(localized: "Sable")
        case .reef:  return String(localized: "Récif")
        case .rock:  return String(localized: "Roche")
        case .mixed: return String(localized: "Mixte")
        }
    }
}

/// Phase de marée idéale d'un spot (gate par-spot, configurable).
enum TideStage: String, Codable, CaseIterable, Identifiable {
    case low, mid, high

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .low:  return String(localized: "Marée basse")
        case .mid:  return String(localized: "Mi-marée")
        case .high: return String(localized: "Marée haute")
        }
    }
}

// MARK: - Période & provenance (honnêteté de la donnée)

/// D'où vient la donnée de houle → pilote l'étiquette de provenance affichée.
enum MarineProvenance: String, Equatable {
    case combinedModel   // houle combinée d'un seul modèle (≈ Open-Meteo actuel)
    case partitioned     // partitions de houle séparées (≥ 2 trains distincts)
    case buoyAnchored    // calé sur une bouée in-situ proche (NDBC/CDIP)

    /// Étiquette honnête : on rappelle toujours le caractère « modèle large, offshore ».
    var label: String {
        switch self {
        case .combinedModel: return String(localized: "Houle modèle (large, offshore)")
        case .partitioned:   return String(localized: "Houle partitionnée (modèle large)")
        case .buoyAnchored:  return String(localized: "Calé sur bouée proche")
        }
    }
}

// MARK: - Taille lisible par un surfeur (du genou au double-overhead)

/// Catégorie de taille de vague affichable. Calée sur la hauteur de déferlement estimée.
enum SurfHeightBucket: String, CaseIterable, Identifiable {
    case flat, knee, waist, chest, head, overhead, doubleOverhead

    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .flat:           return String(localized: "Flat")
        case .knee:           return String(localized: "Genou")
        case .waist:          return String(localized: "Taille")
        case .chest:          return String(localized: "Poitrine")
        case .head:           return String(localized: "Tête")
        case .overhead:       return String(localized: "Au-dessus de la tête")
        case .doubleOverhead: return String(localized: "Double overhead")
        }
    }

    /// Catégorie à partir d'une hauteur de DÉFERLEMENT en mètres (crête-creux).
    static func bucket(forMeters m: Double) -> SurfHeightBucket {
        switch m {
        case ..<0.3:  return .flat
        case ..<0.6:  return .knee
        case ..<1.0:  return .waist
        case ..<1.4:  return .chest
        case ..<1.9:  return .head
        case ..<2.7:  return .overhead
        default:      return .doubleOverhead
        }
    }
}

// MARK: - Tendance de la houle sur la fenêtre

/// La houle monte, tient ou descend sur la fenêtre de session — critère go/no-go fort
/// (un surfeur décide en partie selon que ça « rentre » ou que ça « tombe »).
enum SwellTrend: String, Equatable {
    case building, holding, dropping, unknown

    var localizedName: String {
        switch self {
        case .building: return String(localized: "En hausse")
        case .holding:  return String(localized: "Stable")
        case .dropping: return String(localized: "En baisse")
        case .unknown:  return String(localized: "Tendance inconnue")
        }
    }
    var symbol: String {
        switch self {
        case .building: return "arrow.up.right"
        case .holding:  return "arrow.right"
        case .dropping: return "arrow.down.right"
        case .unknown:  return "minus"
        }
    }
}

// MARK: - Grade de spot pour la CARTE (rôle dynamique, lecture cache seule)

/// Synthèse « coup d'œil » pour la pastille carte d'un spot. `unknown` = pas de cache frais
/// (offline ou non encore fetché) → teinte NEUTRE, jamais une fausse note.
enum SurfGrade: String, Equatable {
    case unknown
    case flat        // pas de vagues exploitables
    case clean       // surfable, propre
    case firing      // taille + propreté + bonne période
    case oversized   // trop gros / dangereux

    var localizedName: String {
        switch self {
        case .unknown:   return String(localized: "Données indisponibles")
        case .flat:      return String(localized: "Flat")
        case .clean:     return String(localized: "Surfable")
        case .firing:    return String(localized: "Ça marche")
        case .oversized: return String(localized: "Trop gros")
        }
    }
    /// Nom de couleur (résolu par la couche d'affichage ; ici on reste data-only).
    var colorName: String {
        switch self {
        case .unknown:   return "gray"
        case .flat:      return "blue"
        case .clean:     return "green"
        case .firing:    return "purple"
        case .oversized: return "red"
        }
    }
}

// MARK: - Métriques surf par heure (DÉRIVÉES, pures)

struct SurfHourMetrics: Equatable {
    let time: Date
    /// Train de houle DOMINANT choisi par ÉNERGIE (Hs²·T), pas par hauteur : une houle longue
    /// « tape » au-dessus de sa hauteur.
    let dominantSwellHeight: Double      // m
    let dominantSwellPeriod: Double      // s
    let dominantSwellDirection: Double?  // deg (provenance)
    /// Indice d'énergie 0–100 SANS UNITÉ (pas de kW) — sépare 2 m/16 s propre de 2 m/7 s de clapot.
    let energyIndex: Double
    /// Hauteur de déferlement ESTIMÉE, en INTERVALLE (m). Komar-Gaughan ± : jamais un point.
    let breakingHeight: ClosedRange<Double>
    /// Exposition au cap du spot 0–1 (la houle est-elle pointée vers le spot ?). nil si cap inconnu.
    let shoreExposure: Double?
    /// Grooming du vent 0–1 (offshore = propre = bon ; INVERSE du kite). nil si cap inconnu.
    let windGrooming: Double?
    /// Pureté 0–1 = houle / (houle + mer du vent). nil si mer du vent inconnue.
    let purity: Double?
    let swellTrend: SwellTrend
    let provenance: MarineProvenance

    /// Assemble les métriques surf d'une heure. Renvoie nil s'il n'y a AUCUNE donnée de vague
    /// (point inland, fetch marine échoué) → l'appelant affiche « indisponible », jamais 0.
    static func make(from f: HourlyForecast, spot: SpotConfig?, trend: SwellTrend = .unknown) -> SurfHourMetrics? {
        guard let dom = SurfMetrics.dominantPartition(f) else { return nil }
        let energy = SurfMetrics.energyIndex(height: dom.height, period: dom.period)
        let breaking = SurfMetrics.breakingHeightRange(height: dom.height, period: dom.period)
        let exposure = SurfMetrics.shoreExposure(swellDirection: dom.direction,
                                                 shoreOrientation: spot?.shoreOrientation)
        let groom = SurfMetrics.windGrooming(windDirection: f.windDirection,
                                             windSpeedKmh: f.windSpeedKmh,
                                             shoreOrientation: spot?.shoreOrientation)
        let purity = SurfMetrics.purity(swellHeight: f.swellHeight, windWaveHeight: f.windWaveHeight)
        let provenance: MarineProvenance = dom.count >= 2 ? .partitioned : .combinedModel
        return SurfHourMetrics(
            time: f.time,
            dominantSwellHeight: dom.height,
            dominantSwellPeriod: dom.period,
            dominantSwellDirection: dom.direction,
            energyIndex: energy,
            breakingHeight: breaking,
            shoreExposure: exposure,
            windGrooming: groom,
            purity: purity,
            swellTrend: trend,
            provenance: provenance
        )
    }
}

// MARK: - Moteur de calcul (logique pure, testable)

enum SurfMetrics {

    /// Distance angulaire circulaire (deg) entre deux caps, dans [0, 180].
    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        abs(((a - b + 540).truncatingRemainder(dividingBy: 360)) - 180)
    }

    /// Sélectionne le train de houle DOMINANT par énergie (Hs²·T) parmi les partitions
    /// disponibles (primaire + secondaire + tertiaire), avec repli sur la mer totale.
    /// - Returns: (hauteur m, période s, direction deg?, période de pic?, nb de partitions),
    ///            ou nil s'il n'y a aucune donnée de vague exploitable.
    /// Un train de houle classé. `energy` = indice 0–100 (Hs²·T saturant), clé de tri décroissant.
    struct SwellPartition { let height: Double; let period: Double; let direction: Double?; let isPeak: Bool; let energy: Double }

    /// SOURCE UNIQUE du classement des trains de houle (énergie décroissante), pour TOUTE l'app :
    /// houle primaire (période de PIC préférée, repli moyenne → mer totale), 2nde, 3e, puis mer
    /// totale en secours — chacune exige h > 0,05 m et t > 0. `dominantPartition`, la courbe
    /// (swellTrains / dominantSwell) et le dashboard surf délèguent TOUS ici → plus de divergence.
    static func partitions(_ f: HourlyForecast) -> [SwellPartition] {
        var ps: [SwellPartition] = []
        func add(_ h: Double?, _ t: Double?, _ d: Double?, isPeak: Bool) {
            if let h, h > 0.05, let t, t > 0 {
                ps.append(SwellPartition(height: h, period: t, direction: d, isPeak: isPeak,
                                         energy: energyIndex(height: h, period: t)))
            }
        }
        let peak = f.swellPeakPeriod
        add(f.swellHeight, peak ?? f.swellPeriod ?? f.wavePeriod, f.swellDirection, isPeak: peak != nil)
        add(f.secondarySwellHeight, f.secondarySwellPeriod, f.secondarySwellDirection, isPeak: false)
        add(f.tertiarySwellHeight, f.tertiarySwellPeriod, f.tertiarySwellDirection, isPeak: false)
        if ps.isEmpty { add(f.waveHeight, f.wavePeriod, f.waveDirection, isPeak: false) }
        return ps.sorted { $0.energy > $1.energy }
    }

    /// - Returns: (hauteur m, période s, direction deg?, période de pic?, nb de partitions),
    ///            ou nil s'il n'y a aucune donnée de vague exploitable.
    static func dominantPartition(_ f: HourlyForecast)
        -> (height: Double, period: Double, direction: Double?, isPeak: Bool, count: Int)? {
        let ps = partitions(f)
        guard let best = ps.first else { return nil }
        return (best.height, best.period, best.direction, best.isPeak, ps.count)
    }

    /// Indice d'énergie 0–100 SANS UNITÉ (on ABANDONNE la prétention en kW : le flux 0,49·Hs²·Te
    /// utilise la période d'énergie Te ≈ 0,9·Tp, pas Tp ; mélanger les deux surévaluerait ~10 %).
    /// Courbe saturante sur Hs²·T (m²·s) : sépare la houle propre longue du clapot court.
    static func energyIndex(height: Double, period: Double) -> Double {
        let raw = height * height * period            // m²·s (proxy d'énergie)
        let idx = 100 * (1 - exp(-raw / 60))          // ~61 à 2 m/15 s, ~91 à 3 m/16 s
        return max(0, min(100, idx))
    }

    /// Hauteur de déferlement ESTIMÉE en INTERVALLE (m). Komar-Gaughan (1972) :
    /// Hb = 0,39·g^(1/5)·(T·Hs²)^(2/5), g = 9,81. On émet ±30 % car on injecte un Hs SPECTRAL
    /// (et non la hauteur monochromatique d'eau profonde équivalente du modèle d'origine) +,
    /// post-ship, une période MOYENNE → estimation large, JAMAIS spot-grade.
    static func breakingHeightRange(height: Double, period: Double) -> ClosedRange<Double> {
        let g = 9.81
        let hb = 0.39 * pow(g, 0.2) * pow(period * height * height, 0.4)
        let lo = max(0, hb * 0.7)
        let hi = hb * 1.3
        return lo...max(lo, hi)
    }

    /// Exposition au cap du spot 0–1 : la houle est-elle pointée vers le spot ?
    /// `shoreOrientation` = cap de la mer ouverte vue du spot ; la direction de houle est
    /// « d'où elle vient » → une houle alignée sur ce cap arrive de face. Houle de derrière
    /// la côte (écart > 90°) → exposition ≈ 0 (ombre). nil si cap ou direction inconnus.
    static func shoreExposure(swellDirection: Double?, shoreOrientation: Double?) -> Double? {
        guard let dir = swellDirection, let orient = shoreOrientation else { return nil }
        let facing = angularDistance(dir, orient)
        return max(0, 1 - facing / 90)
    }

    /// Grooming du vent 0–1, POLARITÉ INVERSE du kite : pour le surf l'offshore est PROPRE (bon).
    /// Vent faible (< ~8 km/h) = glassy quelle que soit la direction ; offshore léger = nettoie
    /// la face ; onshore dégrade (plancher 0,15) ; vent fort lessive tout. nil si cap inconnu.
    static func windGrooming(windDirection: Double?, windSpeedKmh: Double, shoreOrientation: Double?) -> Double? {
        guard let orient = shoreOrientation else { return nil }
        let glassy = max(0, 1 - windSpeedKmh / 12)                       // ~glassy sous 12 km/h
        guard let dir = windDirection else { return glassy }
        let offshoreDir = (orient + 180).truncatingRemainder(dividingBy: 360)   // l'offshore vient de la terre
        let offshoreness = max(0, 1 - angularDistance(dir, offshoreDir) / 90)    // 1 = plein offshore, 0 = onshore
        let blownPenalty = max(0, (windSpeedKmh - 25) / 25)             // dégrade au-delà de ~25, nul vers 50 km/h
        let directional = (0.15 + 0.85 * offshoreness) * max(0, 1 - blownPenalty)
        return max(0, min(1, max(glassy, directional)))
    }

    /// Pureté 0–1 = houle / (houle + mer du vent) : plus la houle domine, plus c'est propre.
    static func purity(swellHeight: Double?, windWaveHeight: Double?) -> Double? {
        guard let sh = swellHeight, sh > 0 else { return nil }
        let ww = max(0, windWaveHeight ?? 0)
        return sh / (sh + ww)
    }

    /// Tendance de la houle autour d'une heure donnée, par delta d'énergie sur ±`windowHours`.
    /// Gratuit : se calcule sur la série horaire déjà en main.
    static func swellTrend(in series: [HourlyForecast], around time: Date, windowHours: Int = 3) -> SwellTrend {
        guard !series.isEmpty else { return .unknown }
        func energy(_ f: HourlyForecast) -> Double? {
            guard let d = dominantPartition(f) else { return nil }
            return energyIndex(height: d.height, period: d.period)
        }
        let window = TimeInterval(windowHours * 3600)
        let before = series.filter { $0.time <= time && $0.time >= time.addingTimeInterval(-window) }.compactMap(energy)
        let after  = series.filter { $0.time >= time && $0.time <= time.addingTimeInterval(window) }.compactMap(energy)
        guard let e0 = before.first, let e1 = after.last else { return .unknown }
        let delta = e1 - e0
        if delta > 6 { return .building }
        if delta < -6 { return .dropping }
        return .holding
    }

    /// Conseil de combinaison selon la température de l'eau (°C). Indicatif (confort), pas une
    /// donnée de sécurité ; la tolérance au froid varie. nil si SST inconnue.
    static func wetsuitAdvice(sst: Double?) -> String? {
        guard let t = sst else { return nil }
        switch t {
        case 24...:      return String(localized: "Boardshort ou 2 mm")
        case 19..<24:    return String(localized: "Combinaison 3/2 mm")
        case 17..<19:    return String(localized: "Combinaison 4/3 mm")
        case 13..<17:    return String(localized: "5/4 mm + chaussons")
        default:         return String(localized: "6/5 mm + chaussons, gants, cagoule")
        }
    }

    // MARK: - Grade pour la pastille CARTE (lecture cache seule, offline-safe)

    /// Synthèse « coup d'œil » pour la carte. Pure sur une `HourlyForecast` déjà en cache.
    /// Renvoie `.unknown` quand il n'y a pas de donnée de vague (l'appelant gère aussi le cas
    /// « pas de prévision en cache » → `.unknown` → teinte neutre, jamais une fausse note).
    static func grade(for f: HourlyForecast, spot: SpotConfig?) -> SurfGrade {
        guard let dom = dominantPartition(f) else { return .unknown }
        if dom.height < 0.3 { return .flat }
        let energy = energyIndex(height: dom.height, period: dom.period)
        let breaking = breakingHeightRange(height: dom.height, period: dom.period)
        let groom = windGrooming(windDirection: f.windDirection,
                                 windSpeedKmh: f.windSpeedKmh,
                                 shoreOrientation: spot?.shoreOrientation) ?? 0.6   // cap inconnu → neutre
        if breaking.upperBound > 3.0 { return .oversized }
        if energy > 55 && groom > 0.6 { return .firing }
        if energy > 18 { return .clean }
        return .flat
    }
}
