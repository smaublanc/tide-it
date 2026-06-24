//
//  HarmonicTideEngine.swift
//  Tide It
//
//  Moteur de prédiction de marées par analyse harmonique astronomique.
//  Utilise les constituants harmoniques standards (IHO/SHOM) pour prédire
//  les marées à n'importe quelle date avec une précision centimétrique.
//
//  La prédiction harmonique est la méthode officielle utilisée par le SHOM,
//  l'IHO, la NOAA et tous les services hydrographiques mondiaux.
//
//  h(t) = Z₀ + Σ fᵢ·Hᵢ·cos(Vᵢ(t) + uᵢ - gᵢ)
//
//  où: Z₀ = niveau moyen, Hᵢ = amplitude, gᵢ = phase (retard),
//      fᵢ = facteur nodal, uᵢ = correction nodale, Vᵢ(t) = argument astronomique
//

import Foundation
import os.log

// MARK: - Constituant Harmonique

/// Un constituant harmonique de marée (M2, S2, K1, O1, etc.)
/// Chaque constituant représente l'influence gravitationnelle d'un corps céleste
/// à une fréquence spécifique.
struct TidalConstituent: Codable, Identifiable {
    let id: String           // Nom standard IHO (M2, S2, N2, K1, O1, etc.)
    let speed: Double        // Vitesse angulaire en degrés/heure
    let amplitude: Double    // Amplitude Hᵢ en mètres (spécifique au port)
    let phase: Double        // Phase gᵢ (retard) en degrés (spécifique au port)

    /// Calcule la contribution de ce constituant à un instant t
    /// - Parameters:
    ///   - hours: Heures depuis l'époque de référence
    ///   - nodalF: Facteur nodal f (correction d'amplitude)
    ///   - nodalU: Correction nodale u en degrés (correction de phase)
    ///   - V0: Argument astronomique initial V₀ en degrés
    func contribution(hours: Double, nodalF: Double, nodalU: Double, V0: Double) -> Double {
        let argument = V0 + speed * hours + nodalU - phase
        return nodalF * amplitude * cos(argument * .pi / 180.0)
    }
}

// MARK: - Vitesses angulaires standard des constituants

/// Vitesses angulaires des constituants harmoniques en degrés/heure
/// Sources : IHO Tidal Constituent Tables, SHOM documentation technique
enum ConstituentSpeed {
    // --- Semi-diurnes (période ~12h) ---
    static let M2  = 28.984104   // Lunaire principal semi-diurne
    static let S2  = 30.000000   // Solaire principal semi-diurne
    static let N2  = 28.439730   // Lunaire elliptique semi-diurne
    static let K2  = 30.082137   // Luni-solaire semi-diurne
    static let _2N2 = 27.895355  // Second elliptique lunaire
    static let MU2 = 27.968208   // Variational lunaire
    static let NU2 = 28.512583   // Evectional lunaire
    static let L2  = 29.528479   // Lunaire semi-diurne (mineur)
    static let T2  = 29.958933   // Solaire semi-diurne (mineur)
    static let LAM2 = 29.455626  // Lambda-2

    // --- Diurnes (période ~24h) ---
    static let K1  = 15.041069   // Luni-solaire diurne
    static let O1  = 13.943036   // Lunaire principal diurne
    static let P1  = 14.958931   // Solaire principal diurne
    static let Q1  = 13.398661   // Lunaire elliptique diurne
    static let J1  = 15.585443   // Petit lunaire diurne
    static let OO1 = 16.139102   // Lunaire diurne de 2ème ordre

    // --- Quart-diurnes (période ~6h) ---
    static let M4  = 57.968208   // Premier harmonique peu profond de M2
    static let MS4 = 58.984104   // Interaction M2+S2
    static let MN4 = 57.423834   // Interaction M2+N2

    // --- Sixième-diurne ---
    static let M6  = 86.952313   // Deuxième harmonique peu profond de M2
    static let _2MS6 = 87.968208 // Interaction 2M2+S2

    // --- Longue période ---
    static let Mf  = 1.098033    // Lunaire bimensuel
    static let Mm  = 0.544375    // Lunaire mensuel
    static let Ssa = 0.082137    // Solaire semi-annuel
    static let Sa  = 0.041069    // Solaire annuel
    static let MSf = 1.015896    // Luni-solaire bimensuel
}

// MARK: - Arguments astronomiques

/// Calcul des arguments astronomiques fondamentaux
/// Basé sur les formules de Meeus (Astronomical Algorithms) et Schureman
struct AstronomicalArguments {
    let T: Double   // Siècles juliens depuis J2000.0
    let s: Double   // Longitude moyenne de la Lune (degrés)
    let h: Double   // Longitude moyenne du Soleil (degrés)
    let p: Double   // Longitude du périgée lunaire (degrés)
    let N: Double   // Longitude du nœud ascendant lunaire (degrés) (Ω)
    let pp: Double  // Longitude du périhélie solaire (degrés)

    /// Initialise les arguments astronomiques pour une date donnée
    init(date: Date) {
        // Jour julien
        let JD = AstronomicalArguments.julianDay(from: date)
        // Siècles juliens depuis J2000.0 (1er janvier 2000 12h TU)
        let T = (JD - 2451545.0) / 36525.0
        self.T = T

        // Longitude moyenne de la Lune (Meeus, ch. 47)
        // s = 218.3165 + 481267.8813·T (degrés)
        self.s = AstronomicalArguments.normalize(
            218.3164477 + 481267.88123421 * T
            - 0.0015786 * T * T
            + T * T * T / 538841.0
            - T * T * T * T / 65194000.0
        )

        // Longitude moyenne du Soleil
        // h = 280.4664 + 36000.7698·T (degrés)
        self.h = AstronomicalArguments.normalize(
            280.46646 + 36000.76983 * T + 0.0003032 * T * T
        )

        // Longitude du périgée lunaire
        // p = 83.3532 + 4069.0137·T (degrés)
        self.p = AstronomicalArguments.normalize(
            83.3532465 + 4069.0137287 * T
            - 0.0103200 * T * T
            - T * T * T / 80053.0
            + T * T * T * T / 18999000.0
        )

        // Longitude du nœud ascendant lunaire (Ω)
        // N = 125.0445 - 1934.1363·T (degrés)
        self.N = AstronomicalArguments.normalize(
            125.04452 - 1934.136261 * T
            + 0.0020708 * T * T
            + T * T * T / 450000.0
        )

        // Longitude du périhélie solaire
        // pp = 282.9373 + 1.7195·T (degrés)
        self.pp = AstronomicalArguments.normalize(
            282.93735 + 1.71946 * T + 0.00046 * T * T
        )
    }

    // MARK: Arguments astronomiques V₀ des constituants

    /// Calcule l'argument astronomique V₀ pour un constituant donné
    func V0(for constituent: String) -> Double {
        switch constituent {
        // Semi-diurnes
        case "M2":   return normalize(2*h - 2*s)
        case "S2":   return 0.0  // V₀ = 0 par convention (référence solaire)
        case "N2":   return normalize(2*h - 3*s + p)
        case "K2":   return normalize(2*h)
        case "2N2":  return normalize(2*h - 4*s + 2*p)
        // Arguments d'équilibre conformes à Schureman/IHO (cohérence vitesse↔argument
        // vérifiée numériquement : le taux de V₀ doit égaler vitesse − espèce·15°/h).
        case "MU2":  return normalize(4*h - 4*s)              // 2(s−h) variation : 2MS2
        case "NU2":  return normalize(4*h - 3*s - p)          // évectionnel
        case "L2":   return normalize(2*h - s - p + 180.0)    // +180° (terme R, Schureman)
        case "T2":   return normalize(-h + pp)
        case "LAM2": return normalize(-s + p + 180.0)

        // Diurnes
        case "K1":   return normalize(h + 90.0)
        case "O1":   return normalize(h - 2*s - 90.0)
        case "P1":   return normalize(-h - 90.0)
        case "Q1":   return normalize(h - 3*s + p - 90.0)
        case "J1":   return normalize(h + s - p + 90.0)
        case "OO1":  return normalize(h + 2*s + 90.0)

        // Quart-diurnes
        case "M4":   return normalize(4*h - 4*s)
        case "MS4":  return normalize(2*h - 2*s)
        case "MN4":  return normalize(4*h - 5*s + p)

        // Sixième-diurnes
        case "M6":   return normalize(6*h - 6*s)
        case "2MS6": return normalize(4*h - 4*s)

        // Longue période
        case "Mf":   return normalize(2*s)
        case "Mm":   return normalize(s - p)
        case "Ssa":  return normalize(2*h)
        case "Sa":   return normalize(h)
        case "MSf":  return normalize(2*s - 2*h)

        default: return 0.0
        }
    }

    // MARK: Facteurs nodaux (f et u)

    /// Facteur nodal f (correction d'amplitude sur le cycle de 18.61 ans)
    func nodalF(for constituent: String) -> Double {
        let Nr = N * .pi / 180.0  // N en radians
        let cosN = cos(Nr)
        let cos2N = cos(2 * Nr)

        switch constituent {
        // Semi-diurnes
        case "M2":
            // f(M2) ≈ 1.0 - 0.037·cos(N)
            return 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
        case "S2", "T2":
            return 1.0  // Pas de correction nodale pour le solaire
        case "N2", "NU2":
            return 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
        case "K2":
            return 1.0241 + 0.2863 * cosN + 0.0083 * cos2N
        case "2N2", "MU2":
            return 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
        case "L2":
            // f(L2) = f(M2)·(1/Rₐ), Schureman éq. 215 :
            //   1/Rₐ = √(1 − 12·tan²(½I)·cos2P + 36·tan⁴(½I)),  P ≈ p (périgée lunaire).
            // L'ancienne version utilisait tan(I)/2 (≈5× trop grand) + abs() masquant un
            // signe négatif → amplitude de L2 fausse de ±70 %.
            let I = acos(0.9136949 - 0.0356926 * cosN)
            let tanHalfI2 = pow(tan(I / 2.0), 2.0)
            let cos2P = cos(2.0 * p * .pi / 180.0)
            let invRa2 = 1.0 - 12.0 * tanHalfI2 * cos2P + 36.0 * tanHalfI2 * tanHalfI2
            let fM2 = 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
            return fM2 * sqrt(max(invRa2, 0.0001))
        case "LAM2":
            return 1.0004 - 0.0373 * cosN + 0.0002 * cos2N

        // Diurnes
        case "K1":
            return 1.0060 + 0.1150 * cosN - 0.0088 * cos2N
        case "O1":
            return 1.0089 + 0.1871 * cosN - 0.0147 * cos2N + 0.0014 * cos(3 * Nr)
        case "P1":
            return 1.0  // Pas de correction nodale
        case "Q1":
            return 1.0089 + 0.1871 * cosN - 0.0147 * cos2N
        case "J1":
            return 1.0060 + 0.1150 * cosN - 0.0088 * cos2N
        case "OO1":
            return 1.1027 + 0.6504 * cosN + 0.0317 * cos2N

        // Quart-diurnes
        case "M4":
            let fM2 = 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
            return fM2 * fM2
        case "MS4":
            return 1.0004 - 0.0373 * cosN + 0.0002 * cos2N  // f(M2)
        case "MN4":
            let fM2 = 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
            return fM2 * fM2

        // Sixième-diurnes
        case "M6":
            let fM2 = 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
            return fM2 * fM2 * fM2
        case "2MS6":
            let fM2 = 1.0004 - 0.0373 * cosN + 0.0002 * cos2N
            return fM2 * fM2

        // Longue période
        case "Mf":
            return 1.0429 + 0.4135 * cosN - 0.004 * cos2N
        case "Mm":
            return 1.0 - 0.130 * cosN
        case "Ssa", "Sa", "MSf":
            return 1.0

        default: return 1.0
        }
    }

    /// Correction nodale u en degrés (correction de phase)
    func nodalU(for constituent: String) -> Double {
        let Nr = N * .pi / 180.0
        let sinN = sin(Nr)
        let sin2N = sin(2 * Nr)

        switch constituent {
        case "M2":
            return -2.14 * sinN
        case "S2", "T2":
            return 0.0
        case "N2", "NU2":
            return -2.14 * sinN
        case "K2":
            return -17.74 * sinN + 0.68 * sin2N
        case "2N2", "MU2":
            return -2.14 * sinN
        case "L2":
            return -2.14 * sinN  // Approximation simplifiée
        case "LAM2":
            return -2.14 * sinN

        case "K1":
            return -8.86 * sinN + 0.68 * sin2N
        case "O1":
            return 10.80 * sinN - 1.34 * sin2N
        case "P1":
            return 0.0
        case "Q1":
            return 10.80 * sinN - 1.34 * sin2N
        case "J1":
            return -8.86 * sinN + 0.68 * sin2N
        case "OO1":
            return -36.68 * sinN + 4.02 * sin2N

        case "M4":
            return -4.28 * sinN  // 2 × u(M2)
        case "MS4":
            return -2.14 * sinN  // u(M2)
        case "MN4":
            return -4.28 * sinN

        case "M6":
            return -6.42 * sinN  // 3 × u(M2)
        case "2MS6":
            return -4.28 * sinN

        case "Mf":
            return -11.36 * sinN + 1.02 * sin2N
        case "Mm":
            return 0.0
        case "Ssa", "Sa", "MSf":
            return 0.0

        default: return 0.0
        }
    }

    // MARK: Utilitaires

    /// Calcule le jour julien à partir d'une Date
    static func julianDay(from date: Date) -> Double {
        // Composants UTC
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let comp = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let Y = Double(comp.year ?? 2000)
        let M = Double(comp.month ?? 1)
        let D = Double(comp.day ?? 1)
        let H = Double(comp.hour ?? 0)
        let Min = Double(comp.minute ?? 0)
        let S = Double(comp.second ?? 0)

        // Algorithme de Meeus
        var y = Y, m = M
        if m <= 2 {
            y -= 1
            m += 12
        }

        let A = floor(y / 100.0)
        let B = 2.0 - A + floor(A / 4.0)

        let JD = floor(365.25 * (y + 4716.0))
                + floor(30.6001 * (m + 1.0))
                + D + B - 1524.5
                + (H + Min / 60.0 + S / 3600.0) / 24.0

        return JD
    }

    /// Normalise un angle en degrés dans [0, 360)
    private func normalize(_ angle: Double) -> Double {
        AstronomicalArguments.normalize(angle)
    }

    static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360.0)
        if a < 0 { a += 360.0 }
        return a
    }
}

// MARK: - Constantes harmoniques par port

/// Constantes harmoniques pour un port donné
/// Calibrées à partir des données historiques SHOM
struct PortHarmonics: Codable, Identifiable {
    let id: String                       // Port ID (correspond à shom_ports.txt)
    let meanSeaLevel: Double             // Z₀ : niveau moyen (mètres au-dessus du zéro hydro)
    let constituents: [TidalConstituent] // Les constituants harmoniques avec amplitude et phase

    /// Vérifie la validité des constantes
    var isValid: Bool {
        !constituents.isEmpty && constituents.contains { $0.id == "M2" }
    }
}

// MARK: - Version du moteur de prédiction

/// Version des PRÉDICTIONS du moteur. À INCRÉMENTER à chaque changement qui modifie les
/// hauteurs/horaires produits (Z₀, clamp, constituants, recalage, dérivation de datum…).
/// `TideCache` inclut cette version dans sa clé disque → toute hausse invalide
/// AUTOMATIQUEMENT les prédictions cachées par une version antérieure (plus besoin de
/// jongler avec un flag de migration pour le cache).
/// v8 (juin 2026) : retrait du clamp `max(0,h)` + dérivation Z₀ synchrone garantie.
/// v9 (juin 2026) : datum SHOM publié (niveau moyen / zéro hydro) pour 10 ports FR de
/// référence → corrige le biais de hauteur ~0,1-0,44 m (les hauteurs changent → cache à invalider).
/// v10 (juin 2026) : exclusion des marégraphes fluviaux Vigicrues du rattachement FR (marée
/// amortie → marnage trop faible, ex. Locquemeau −3,3 m) → les ports côtiers se relient à une
/// vraie station côtière (hauteurs changent → cache à invalider).
/// v11 (juin 2026) : PURGE des calibrations réseau héritées (obsolètes, app offline) qui
/// gonflaient certains ports (San Francisco 4,45 m + faux coef) → le moteur n'utilise plus que
/// les harmoniques embarquées (hauteurs corrigées → cache à invalider).
/// v12 (juin 2026) : invalidation FORCÉE des entrées v11 résiduelles qui servaient encore un
/// faux coefficient sur les ports à marée MIXTE (ex. San Francisco F≈0,84 : hauteurs déjà
/// recalculées correctes, mais le coef SHOM restait collé dans le cache). Le gate
/// `isSemidiurnal` est vérifié correct → un recalcul propre supprime le coef. Aucune logique
/// moteur ne change ici : on garantit juste un cache 100 % sain.
/// v13 (juin 2026) : coefficient de marée réservé à la MÉTROPOLE. Les ports français d'OUTRE-MER
/// (Polynésie, Nouvelle-Calédonie, Réunion, Antilles…) n'affichent plus le coefficient national
/// de Brest (absurde : ex. Papeete, marée verrouillée sur le soleil, recevait coef 104). Le coef
/// change pour ces ports → cache à invalider.
/// v14 (juin 2026) : INVALIDATION des hauteurs disque périmées. Le cache disque (TideCache, qui ne
/// persiste QUE le tableau proche `tideData`) pouvait servir à la courbe une hauteur FAUSSE écrite
/// par une build antérieure (calibration réseau héritée non encore purgée), pendant que le
/// calendrier recalculait juste — d'où « courbe juste, calendrier faux » (ou l'inverse). Le
/// nettoyage forcé est désormais lié À CETTE VERSION (cf. TideService `engineCleanWipe_v…`) → tout
/// repart propre. Coupler à la purge des calibrations (loadCalibratedHarmonics).
let tideEnginePredictionVersion = 14

// MARK: - Moteur de prédiction harmonique

/// Moteur de prédiction de marées par analyse harmonique
/// Prédit les hauteurs d'eau et les heures de PM/BM pour n'importe quelle date
@MainActor
class HarmonicTideEngine: ObservableObject {
    static let shared = HarmonicTideEngine()

    @Published var extendedPredictions: [TideData] = []
    @Published var isPredicting = false
    @Published var predictionAccuracy: PredictionAccuracy = .uncalibrated

    /// Base de données des constantes harmoniques
    private var harmonicsDB: [String: PortHarmonics] = [:]

    /// Constantes calibrées par apprentissage sur données SHOM
    private var calibratedHarmonics: [String: PortHarmonics] = [:]

    /// IDs des ports français (façade SHOM) → leur coefficient de marée suit la convention
    /// SHOM : valeur NATIONALE calculée à BREST, identique pour tous les ports français un
    /// jour donné (et non un calcul local par port, qui dérivait de ±5 points — ex. Arcachon,
    /// bassin filtré au ratio M2/S2 très différent de Brest).
    private(set) var frenchPortIds: Set<String> = []

    /// Sous-ensemble des ports français HORS métropole (Polynésie, Nouvelle-Calédonie, Réunion,
    /// Antilles, Guyane, Mayotte, St-Pierre…). Le coefficient de marée (échelle SHOM, ancré à
    /// BREST) n'a AUCUN sens là-bas : la marée du Pacifique / Océan Indien / Caraïbes n'est pas
    /// corrélée à celle de Brest — le SHOM lui-même n'y publie pas de coefficient (« --- »).
    /// → ces ports n'affichent jamais de coefficient.
    private(set) var overseasFrenchPortIds: Set<String> = []

    /// Vrai si le port est français ET métropolitain (Corse comprise) : seul cas où le
    /// coefficient national de Brest s'applique.
    private func isMetropolitanFrench(_ portId: String) -> Bool {
        frenchPortIds.contains(portId) && !overseasFrenchPortIds.contains(portId)
    }

    /// Port de référence du coefficient national (SHOM le calcule à Brest).
    private static let coefficientReferencePortId = "BREST"

    /// Déclare les ports français + l'ancrage coef-95 de Brest (PRÉ-CALCULÉ hors-main par
    /// l'appelant, dans la même tâche que le chargement des harmoniques FR — donc prêt AVANT
    /// toute prédiction française, ce qui rend le coefficient déterministe dès le 1er affichage).
    func setFrenchPortIds(_ ids: Set<String>, overseas: Set<String> = [], brestAnchor: Double?) {
        frenchPortIds = ids
        overseasFrenchPortIds = overseas
        if let a = brestAnchor, a > 0 { coef95Anchor[Self.coefficientReferencePortId] = a }
        predictionCache.removeAll()   // recalcule les coefficients avec la référence Brest
    }

    /// Cache des prédictions
    private var predictionCache: [String: (date: Date, tides: [TideData])] = [:]
    private let cacheDuration: TimeInterval = 3600 * 6 // 6h
    private let maxCacheEntries = 200

    /// Écriture BORNÉE dans le cache : purge les entrées périmées puis plafonne le nombre
    /// (éviction des plus anciennes). Sans cela, le dictionnaire — sur un singleton à vie process —
    /// croît indéfiniment quand on parcourt beaucoup de ports/fenêtres (audit : cache non borné).
    private func storeInCache(_ key: String, _ tides: [TideData]) {
        let now = Date()
        predictionCache[key] = (now, tides)
        predictionCache = predictionCache.filter { now.timeIntervalSince($0.value.date) < cacheDuration }
        if predictionCache.count > maxCacheEntries {
            let overflow = predictionCache.count - maxCacheEntries
            for k in predictionCache.sorted(by: { $0.value.date < $1.value.date }).prefix(overflow).map(\.key) {
                predictionCache.removeValue(forKey: k)
            }
        }
    }

    enum PredictionAccuracy: String {
        case uncalibrated = "Non calibré"
        case calibrating = "Calibrage..."
        case low = "Précision faible"
        case medium = "Précision moyenne"
        case high = "Haute précision"
        case veryHigh = "Très haute précision"

        var localizedName: String {
            switch self {
            case .uncalibrated: return String(localized: "Non calibré")
            case .calibrating:  return String(localized: "Calibrage...")
            case .low:          return String(localized: "Précision faible")
            case .medium:       return String(localized: "Précision moyenne")
            case .high:         return String(localized: "Haute précision")
            case .veryHigh:     return String(localized: "Très haute précision")
            }
        }

        var icon: String {
            switch self {
            case .uncalibrated: return "circle.dashed"
            case .calibrating: return "arrow.triangle.2.circlepath"
            case .low: return "circle.bottomhalf.filled"
            case .medium: return "circle.inset.filled"
            case .high: return "checkmark.circle.fill"
            case .veryHigh: return "star.circle.fill"
            }
        }

        var color: String {
            switch self {
            case .uncalibrated: return "gray"
            case .calibrating: return "orange"
            case .low: return "yellow"
            case .medium: return "green"
            case .high: return "cyan"
            case .veryHigh: return "purple"
            }
        }
    }

    init() {
        loadBuiltInHarmonics()
        loadCalibratedHarmonics()
    }

    // MARK: - Prédiction

    /// Prédit la hauteur d'eau à un instant donné pour un port
    func predictHeight(at date: Date, portId: String) -> Double? {
        guard let harmonics = bestHarmonics(for: portId) else { return nil }

        // Époque de référence : début de l'année UTC. ⚠️ V₀ DOIT être évalué à
        // l'ÉPOQUE (le terme ωᵢ·t porte ensuite l'évolution) — l'évaluer à `date`
        // comptait l'évolution lunaire deux fois (~50 min de dérive/jour sur M2).
        let refDate = startOfYearUTC(for: date)
        let refAstro = AstronomicalArguments(date: refDate)
        let astro = AstronomicalArguments(date: date)   // f/u (variations lentes 18,6 ans)
        let hours = date.timeIntervalSince(refDate) / 3600.0

        // h(t) = Z₀ + Σ fᵢ·Hᵢ·cos(V₀ᵢ + ωᵢ·t + uᵢ - gᵢ)
        var height = harmonics.meanSeaLevel

        for constituent in harmonics.constituents {
            let f = astro.nodalF(for: constituent.id)
            let u = astro.nodalU(for: constituent.id)
            let V0 = refAstro.V0(for: constituent.id)

            height += constituent.contribution(hours: hours, nodalF: f, nodalU: u, V0: V0)
        }

        // Hauteur BRUTE (peut passer SOUS le zéro hydro). On NE clampe PAS : sinon une basse
        // mer réelle sous le datum est aplatie à 0 et DISPARAÎT des extrema (San Francisco
        // perdait 2 BM/jour, Seattle sa BM à −1,3 m). Les marées passent réellement sous le
        // zéro hydro — NOAA publie des hauteurs négatives. Un éventuel plancher = à l'affichage.
        return height
    }

    /// Prédit les heures de PM et BM (pleines mers et basses mers) sur une période
    func predictTides(from startDate: Date, to endDate: Date, portId: String) -> [TideData] {
        // Garantir le Z₀ AVANT le cache et l'échantillonnage : sinon les basses mers d'un
        // port mondial sont écrêtées à 0 et disparaissent (cf. ensureChartDatumSync).
        ensureChartDatumSync(for: portId)
        // Vérifier le cache
        let cacheKey = "\(portId)_\(Int(startDate.timeIntervalSince1970))_\(Int(endDate.timeIntervalSince1970))"
        if let cached = predictionCache[cacheKey],
           Date().timeIntervalSince(cached.date) < cacheDuration {
            return cached.tides
        }

        guard bestHarmonics(for: portId) != nil else { return [] }

        // Échantillonner toutes les 3 minutes pour trouver les extrema avec précision
        let step: TimeInterval = 180 // 3 minutes
        var heights: [(date: Date, height: Double)] = []
        var current = startDate.addingTimeInterval(-step) // Un peu avant
        let end = endDate.addingTimeInterval(step) // Un peu après

        while current <= end {
            if let h = predictHeight(at: current, portId: portId) {
                heights.append((current, h))
            }
            current = current.addingTimeInterval(step)
        }

        guard heights.count >= 3 else { return [] }

        // Trouver les extrema locaux (PM = max local, BM = min local)
        var tides: [TideData] = []

        for i in 1..<(heights.count - 1) {
            let prev = heights[i - 1].height
            let curr = heights[i].height
            let next = heights[i + 1].height

            let isLocalMax = curr > prev && curr > next
            let isLocalMin = curr < prev && curr < next

            if isLocalMax || isLocalMin {
                // Affiner par interpolation parabolique (Newton)
                let (refinedDate, refinedHeight) = refineExtremum(
                    p0: heights[i - 1], p1: heights[i], p2: heights[i + 1]
                )

                // Filtrer les extrema dans la période demandée
                guard refinedDate >= startDate && refinedDate <= endDate else { continue }

                // Vérifier qu'on n'a pas un doublon (distance min 3h entre 2 extrema)
                if let lastTide = tides.last {
                    let gap = refinedDate.timeIntervalSince(lastTide.date)
                    guard gap > 3 * 3600 else { continue } // Min 3h entre 2 extrema
                }

                // Coefficient brut pour les PM — UNIQUEMENT pour les ports FRANÇAIS (puis
                // remplacé par le coef national). Pour les ports mondiaux : nil ici, le
                // coefficient ne vient que du chemin ancré (`withCalibratedCoefficients`),
                // jamais de l'estimation brute (M2+S2) qui sature à 120.
                let coefficient: Int?
                if isLocalMax, isMetropolitanFrench(portId) {
                    let prevLow = tides.last.flatMap { $0.isHighTide ? nil : $0.height }
                    coefficient = estimateCoefficient(
                        highTideHeight: refinedHeight,
                        lowTideHeight: prevLow,
                        portId: portId
                    )
                } else {
                    coefficient = nil
                }

                let tide = TideData(
                    date: refinedDate,
                    height: round(refinedHeight * 100) / 100.0,
                    isHighTide: isLocalMax,
                    coefficient: coefficient
                )
                tides.append(tide)
            }
        }

        // Trier par date + recalage fin éventuel
        tides.sort { $0.date < $1.date }
        tides = applyTimeOffset(tides, portId: portId)
        // Coefficient SHOM national (Brest) pour les ports français.
        tides = withCalibratedCoefficients(tides, portId: portId, from: startDate, to: endDate)

        // Sauvegarder en cache
        storeInCache(cacheKey, tides)

        return tides
    }

    /// Prédit les marées étendues (J8 à J30+) pour un port
    func predictExtended(portId: String, fromDay: Int = 8, toDays: Int = 30) async {
        isPredicting = true

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        guard let startDate = calendar.date(byAdding: .day, value: fromDay, to: today),
              let endDate = calendar.date(byAdding: .day, value: toDays, to: today) else {
            isPredicting = false
            return
        }

        // Prédire sur un thread de fond (calcul intensif)
        let tides = await predictTidesAsync(from: startDate, to: endDate, portId: portId)

        extendedPredictions = tides
        isPredicting = false
    }

    /// Version asynchrone de `predictTides` qui déplace le calcul harmonique lourd
    /// (~14 400 itérations trigonométriques pour 30 jours) sur un thread de fond.
    /// Le cache et les harmoniques sont lus/écrits sur MainActor ; seule la boucle
    /// de prédiction tourne en background.
    func predictTidesAsync(from startDate: Date, to endDate: Date, portId: String) async -> [TideData] {
        // Z₀ garanti AVANT le cache et le snapshot des harmoniques (sinon BM écrêtées → perdues).
        ensureChartDatumSync(for: portId)
        // 1) Cache hit sur MainActor
        let cacheKey = "\(portId)_\(Int(startDate.timeIntervalSince1970))_\(Int(endDate.timeIntervalSince1970))"
        if let cached = predictionCache[cacheKey],
           Date().timeIntervalSince(cached.date) < cacheDuration {
            return cached.tides
        }

        // 2) Snapshot immuable des harmoniques sur MainActor
        guard let harmonics = bestHarmonics(for: portId) else { return [] }
        let coefContext = calibratedHarmonics[portId] ?? harmonicsDB[portId]
        // Coefficient SHOM affiché UNIQUEMENT en MÉTROPOLE (référence Brest, validé EXACT vs
        // SHOM). Partout ailleurs — ports mondiaux ET outre-mer français — AUCUN coefficient :
        // la notion est française/métropolitaine, on n'affiche pas ce dont on n'est pas sûr.
        let isMetroFrench = isMetropolitanFrench(portId)
        let brest = isMetroFrench ? harmonicsDB[Self.coefficientReferencePortId] : nil
        let u95 = isMetroFrench ? coef95Anchor[Self.coefficientReferencePortId] : nil
        let coefOK = isMetroFrench

        // 3) Calcul pur en background (extrema du port + coefficient calibré)
        let tides = await Task.detached(priority: .userInitiated) {
            // coefContext nil hors métropole → on N'UTILISE PAS l'estimation brute
            // (M2+S2, qui sature à 120). Le coefficient ne vient QUE du chemin national/ancrage.
            var t = Self.computeExtrema(
                from: startDate, to: endDate,
                harmonics: harmonics, coefContext: isMetroFrench ? coefContext : nil)
            if coefOK, let u95, let brest {   // métropole uniquement : marnage de Brest (coef national)
                let brestTides = Self.computeExtrema(
                    from: startDate.addingTimeInterval(-15 * 3600),
                    to: endDate.addingTimeInterval(15 * 3600),
                    harmonics: brest, coefContext: nil)
                t = Self.applyNationalCoefficients(t, brestTides: brestTides, coef95SemiRange: u95)
            }
            return t
        }.value

        // 4) Recalage fin + cache update sur MainActor
        let adjusted = applyTimeOffset(tides, portId: portId)
        storeInCache(cacheKey, adjusted)
        return adjusted
    }

    /// Calcul pur des extrema (PM/BM) — n'accède à aucun état MainActor, peut
    /// tourner sur n'importe quel thread.
    private nonisolated static func computeExtrema(
        from startDate: Date,
        to endDate: Date,
        harmonics: PortHarmonics,
        coefContext: PortHarmonics?
    ) -> [TideData] {
        let step: TimeInterval = 180 // 3 minutes
        var heights: [(date: Date, height: Double)] = []
        var current = startDate.addingTimeInterval(-step)
        let end = endDate.addingTimeInterval(step)

        // Hoist STRICTEMENT identique : refDate (= début d'année UTC) et refAstro (V₀ à
        // l'époque) sont invariants sur toute une année. Sans ce cache, chaque échantillon
        // (≈3360/fenêtre) recréait un Calendar (startOfYearUTC) + un AstronomicalArguments.
        // On ne les recalcule qu'au franchissement d'année. Pour tout `d` ∈ [yearStart,
        // nextYearStart[, startOfYearUTC(d) == yearStart → résultat bit-identique à avant.
        var yearStart = startOfYearUTCStatic(for: current)
        var refAstro = AstronomicalArguments(date: yearStart)
        var nextYearStart = startOfYearUTCStatic(for: yearStart.addingTimeInterval(366 * 86_400))

        while current <= end {
            if current >= nextYearStart {
                yearStart = startOfYearUTCStatic(for: current)
                refAstro = AstronomicalArguments(date: yearStart)
                nextYearStart = startOfYearUTCStatic(for: yearStart.addingTimeInterval(366 * 86_400))
            }
            let h = heightAt(date: current, harmonics: harmonics, refDate: yearStart, refAstro: refAstro)
            heights.append((current, h))
            current = current.addingTimeInterval(step)
        }

        guard heights.count >= 3 else { return [] }

        var tides: [TideData] = []
        for i in 1..<(heights.count - 1) {
            let prev = heights[i - 1].height
            let curr = heights[i].height
            let next = heights[i + 1].height

            let isLocalMax = curr > prev && curr > next
            let isLocalMin = curr < prev && curr < next

            if isLocalMax || isLocalMin {
                // Interpolation parabolique simple
                let d = prev - 2 * curr + next
                let offsetSec: TimeInterval
                if abs(d) > 1e-9 {
                    let offset = (prev - next) / (2 * d)
                    offsetSec = offset * step
                } else {
                    offsetSec = 0
                }
                let refinedDate = heights[i].date.addingTimeInterval(offsetSec)
                let refinedHeight = curr - (prev - next) * (prev - next) / (8 * d == 0 ? 1 : 8 * d)

                guard refinedDate >= startDate && refinedDate <= endDate else { continue }
                if let lastTide = tides.last {
                    let gap = refinedDate.timeIntervalSince(lastTide.date)
                    guard gap > 3 * 3600 else { continue }
                }

                // Coefficient brut UNIQUEMENT si un coefContext est fourni (ports FR). Pour les
                // ports mondiaux, coefContext == nil → coefficient laissé nil ici (il viendra
                // exclusivement du chemin national/ancrage, jamais de l'estimation brute qui sature).
                let prevLow = isLocalMax ? tides.last.flatMap({ $0.isHighTide ? nil : $0.height }) : nil
                let coefficient: Int? = (isLocalMax && coefContext != nil)
                    ? estimateCoefficient(highTideHeight: refinedHeight, lowTideHeight: prevLow,
                                          harmonics: coefContext!)
                    : nil
                let tide = TideData(
                    date: refinedDate,
                    height: round(refinedHeight * 100) / 100.0,
                    isHighTide: isLocalMax,
                    coefficient: coefficient
                )
                tides.append(tide)
            }
        }

        tides.sort { $0.date < $1.date }
        return tides
    }

    /// Version nonisolated de `predictHeight` qui ne dépend que des arguments passés.
    /// ⚠️ V₀ à l'ÉPOQUE (début d'année UTC), pas à `date` — l'évaluer à la date
    /// comptait l'évolution lunaire deux fois (~50 min de dérive/jour sur M2).
    /// `refDate` / `refAstro` (V₀ à l'époque, invariants par année) sont fournis par l'appelant
    /// pour ne pas les recalculer à chaque échantillon — voir le hoist dans `computeExtrema`.
    private nonisolated static func heightAt(date: Date, harmonics: PortHarmonics,
                                             refDate: Date, refAstro: AstronomicalArguments) -> Double {
        let astro = AstronomicalArguments(date: date)   // f/u : variations lentes (18,6 ans)
        let hours = date.timeIntervalSince(refDate) / 3600.0

        var height = harmonics.meanSeaLevel
        for constituent in harmonics.constituents {
            let f = astro.nodalF(for: constituent.id)
            let u = astro.nodalU(for: constituent.id)
            let V0 = refAstro.V0(for: constituent.id)
            height += constituent.contribution(hours: hours, nodalF: f, nodalU: u, V0: V0)
        }
        return height   // pas de clamp : cf. predictHeight (les BM sous le datum doivent rester)
    }

    private nonisolated static func startOfYearUTCStatic(for date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: "UTC") { cal.timeZone = tz }
        let comps = cal.dateComponents([.year], from: date)
        return cal.date(from: comps) ?? date
    }

    // MARK: - Zéro hydrographique auto-dérivé

    /// Dérive le Z₀ (niveau moyen au-dessus du zéro des cartes) à partir des seuls
    /// constituants : le zéro hydrographique ≈ la plus basse mer astronomique, donc
    /// Z₀ = −min(hauteur prédite autour du niveau moyen) sur ≈ 1 an (couvre le cycle
    /// lunaire complet des vives-eaux). Balayage horaire + affinage à 5 min autour du
    /// minimum. Pur → exécutable hors MainActor (PortCatalog, arrière-plan).
    nonisolated static func chartDatumZ0(constituents: [TidalConstituent]) -> Double {
        // Hauteur BRUTE autour du niveau moyen (peut être négative, pas de clamp).
        // ⚠️ V₀ à l'ÉPOQUE (début d'année UTC) — voir predictHeight.
        // `refDate`/`refAstro` (V₀ à l'époque) invariants par année → fournis par l'appelant
        // (hoist, voir computeExtrema). Sans ça chaque échantillon recréait Calendar + refAstro.
        func rawHeight(at date: Date, refDate: Date, refAstro: AstronomicalArguments) -> Double {
            let astro = AstronomicalArguments(date: date)
            let hours = date.timeIntervalSince(refDate) / 3600.0
            var h = 0.0
            for c in constituents {
                h += c.contribution(hours: hours,
                                    nodalF: astro.nodalF(for: c.id),
                                    nodalU: astro.nodalU(for: c.id),
                                    V0: refAstro.V0(for: c.id))
            }
            return h
        }

        // ⚠️ Ancre FIXE (et non `Date()`) : le zéro hydrographique est une référence
        // CONSTANTE. Scanner depuis l'instant courant faisait dériver le Z₀ d'un lancement
        // à l'autre (et d'une année à l'autre). Le LAT théorique demande le cycle nodal
        // complet (18,6 ans), inabordable par port au lancement ; 425 jours capturent le
        // battement périgée-vive-eau (~411 j) quelle que soit la phase de départ.
        let start = startOfYearUTCStatic(for: Date(timeIntervalSince1970: 1_577_836_800)) // 2020-01-01 UTC
        var minH = Double.infinity
        var minDate = start
        // Cache année courante (recalé au franchissement) — exactement comme avant échantillon.
        var yearStart = startOfYearUTCStatic(for: start)
        var refAstro = AstronomicalArguments(date: yearStart)
        var nextYearStart = startOfYearUTCStatic(for: yearStart.addingTimeInterval(366 * 86_400))
        for i in 0..<(425 * 24) {
            let d = start.addingTimeInterval(Double(i) * 3600)
            if d >= nextYearStart {
                yearStart = startOfYearUTCStatic(for: d)
                refAstro = AstronomicalArguments(date: yearStart)
                nextYearStart = startOfYearUTCStatic(for: yearStart.addingTimeInterval(366 * 86_400))
            }
            let h = rawHeight(at: d, refDate: yearStart, refAstro: refAstro)
            if h < minH { minH = h; minDate = d }
        }
        // Affinage ±1 h au pas de 5 min (peut chevaucher un changement d'année → on recale).
        var t = minDate.addingTimeInterval(-3600)
        let end = minDate.addingTimeInterval(3600)
        while t <= end {
            if t >= nextYearStart || t < yearStart {
                yearStart = startOfYearUTCStatic(for: t)
                refAstro = AstronomicalArguments(date: yearStart)
                nextYearStart = startOfYearUTCStatic(for: yearStart.addingTimeInterval(366 * 86_400))
            }
            let h = rawHeight(at: t, refDate: yearStart, refAstro: refAstro)
            if h < minH { minH = h }
            t = t.addingTimeInterval(300)
        }
        // Z₀ = profondeur du creux le plus bas (jamais négatif), arrondi au cm.
        return max(0, (-minH * 100).rounded() / 100)
    }

    // MARK: - Calibrage automatique

    /// Calibre les constantes harmoniques d'un port à partir des données SHOM réelles
    /// Utilise la méthode des moindres carrés pour ajuster amplitudes et phases
    func calibrate(portId: String, shomTides: [TideData]) {
        guard shomTides.count >= 8 else { return } // Min 2 jours de données

        predictionAccuracy = .calibrating

        // Récupérer les harmoniques de base (ou créer depuis le template)
        let harmonics = harmonicsDB[portId] ?? generateDefaultHarmonics(portId: portId, fromTides: shomTides)

        // Étape 1 : Calibrer le niveau moyen Z₀
        let shomHeights = shomTides.map(\.height)
        let observedMean = shomHeights.reduce(0, +) / Double(shomHeights.count)

        // Étape 2 : Calculer les amplitudes et phases depuis les données
        // Méthode : analyse des PM/BM pour extraire M2, S2, K1, O1
        let calibrated = calibrateFromExtrema(
            baseHarmonics: harmonics,
            observedTides: shomTides,
            observedMean: observedMean
        )

        // Étape 3 : Valider par comparaison
        let accuracy = validateCalibration(
            calibrated: calibrated,
            observedTides: shomTides
        )

        // Sauvegarder
        calibratedHarmonics[portId] = calibrated
        saveCalibratedHarmonics()

        predictionAccuracy = accuracy
    }

    /// Calibrage depuis les extrema (PM/BM) SHOM
    private func calibrateFromExtrema(
        baseHarmonics: PortHarmonics,
        observedTides: [TideData],
        observedMean: Double
    ) -> PortHarmonics {
        let highTides = observedTides.filter { $0.isHighTide }
        let lowTides = observedTides.filter { !$0.isHighTide }

        guard !highTides.isEmpty && !lowTides.isEmpty else { return baseHarmonics }

        let avgHigh = highTides.map(\.height).reduce(0, +) / Double(highTides.count)
        let avgLow = lowTides.map(\.height).reduce(0, +) / Double(lowTides.count)
        let maxHigh = highTides.map(\.height).max() ?? avgHigh
        let minLow = lowTides.map(\.height).min() ?? avgLow

        // Marnage moyen et maximal
        let meanRange = avgHigh - avgLow
        let maxRange = maxHigh - minLow

        // Niveau moyen réel
        let Z0 = (avgHigh + avgLow) / 2.0

        // Extraire M2 (composant dominant, ~70% du marnage)
        let M2_amplitude = meanRange / 2.0 * 0.92  // M2 = ~92% du demi-marnage moyen

        // S2 déduit du rapport marnage max/moyen (effet vives-eaux / mortes-eaux)
        // Vives-eaux : M2+S2, Mortes-eaux : M2-S2
        // maxRange ≈ 2*(M2+S2), meanRange ≈ 2*M2
        let S2_amplitude = max(0, (maxRange - meanRange) / 2.0 * 0.85)

        // N2 (variation elliptique) ≈ 19% de M2
        let N2_amplitude = M2_amplitude * 0.19

        // K2 ≈ 27% de S2
        let K2_amplitude = S2_amplitude * 0.27

        // K1 et O1 (composantes diurnes) - déduites de l'asymétrie des marées
        let tidalAsymmetry = calculateTidalAsymmetry(tides: observedTides)
        let K1_amplitude = meanRange * 0.08 * (1.0 + tidalAsymmetry)
        let O1_amplitude = K1_amplitude * 0.75
        let P1_amplitude = K1_amplitude * 0.33
        let Q1_amplitude = O1_amplitude * 0.19

        // M4 (quart-diurne, eaux peu profondes) - déduit de l'asymétrie montant/descendant
        let shallowWaterRatio = calculateShallowWaterRatio(tides: observedTides)
        let M4_amplitude = M2_amplitude * 0.05 * shallowWaterRatio
        let MS4_amplitude = M4_amplitude * 0.4

        // Phase de M2 : calculée depuis l'heure de la première PM
        let M2_phase = calculateM2Phase(from: observedTides)

        // Phases dérivées (relations astronomiques connues)
        let S2_phase = M2_phase + estimateS2PhaseOffset(from: observedTides)
        let N2_phase = M2_phase - 20.0   // Typiquement en avance de ~20°
        let K2_phase = S2_phase + 2.0
        let K1_phase = M2_phase / 2.0 + 90.0
        let O1_phase = M2_phase / 2.0 - 30.0
        let P1_phase = K1_phase - 2.0
        let Q1_phase = O1_phase - 20.0
        let M4_phase = 2.0 * M2_phase + 15.0
        let MS4_phase = M2_phase + S2_phase + 10.0

        // Constituants mineurs estimés
        let MU2_amplitude = M2_amplitude * 0.025
        let NU2_amplitude = N2_amplitude * 0.19
        let L2_amplitude = M2_amplitude * 0.03
        let _2N2_amplitude = N2_amplitude * 0.13
        let T2_amplitude = S2_amplitude * 0.06
        let J1_amplitude = K1_amplitude * 0.07
        let M6_amplitude = M2_amplitude * 0.01 * shallowWaterRatio

        // Construire les constituants calibrés
        var constituents: [TidalConstituent] = [
            TidalConstituent(id: "M2",  speed: ConstituentSpeed.M2,  amplitude: M2_amplitude,  phase: M2_phase),
            TidalConstituent(id: "S2",  speed: ConstituentSpeed.S2,  amplitude: S2_amplitude,  phase: S2_phase),
            TidalConstituent(id: "N2",  speed: ConstituentSpeed.N2,  amplitude: N2_amplitude,  phase: N2_phase),
            TidalConstituent(id: "K2",  speed: ConstituentSpeed.K2,  amplitude: K2_amplitude,  phase: K2_phase),
            TidalConstituent(id: "K1",  speed: ConstituentSpeed.K1,  amplitude: K1_amplitude,  phase: K1_phase),
            TidalConstituent(id: "O1",  speed: ConstituentSpeed.O1,  amplitude: O1_amplitude,  phase: O1_phase),
            TidalConstituent(id: "P1",  speed: ConstituentSpeed.P1,  amplitude: P1_amplitude,  phase: P1_phase),
            TidalConstituent(id: "Q1",  speed: ConstituentSpeed.Q1,  amplitude: Q1_amplitude,  phase: Q1_phase),
            TidalConstituent(id: "M4",  speed: ConstituentSpeed.M4,  amplitude: M4_amplitude,  phase: M4_phase),
            TidalConstituent(id: "MS4", speed: ConstituentSpeed.MS4, amplitude: MS4_amplitude, phase: MS4_phase),
        ]

        // Ajouter les constituants mineurs s'ils sont significatifs (> 1cm)
        if N2_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "2N2", speed: ConstituentSpeed._2N2, amplitude: _2N2_amplitude, phase: N2_phase - 20.0))
        }
        if MU2_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "MU2", speed: ConstituentSpeed.MU2, amplitude: MU2_amplitude, phase: M2_phase + 180.0))
        }
        if NU2_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "NU2", speed: ConstituentSpeed.NU2, amplitude: NU2_amplitude, phase: N2_phase + 5.0))
        }
        if L2_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "L2", speed: ConstituentSpeed.L2, amplitude: L2_amplitude, phase: M2_phase + 180.0))
        }
        if T2_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "T2", speed: ConstituentSpeed.T2, amplitude: T2_amplitude, phase: S2_phase - 5.0))
        }
        if J1_amplitude > 0.01 {
            constituents.append(TidalConstituent(id: "J1", speed: ConstituentSpeed.J1, amplitude: J1_amplitude, phase: K1_phase + 20.0))
        }
        if M6_amplitude > 0.005 {
            constituents.append(TidalConstituent(id: "M6", speed: ConstituentSpeed.M6, amplitude: M6_amplitude, phase: 3.0 * M2_phase))
        }

        // Longue période (corrections saisonnières)
        constituents.append(TidalConstituent(id: "Sa", speed: ConstituentSpeed.Sa, amplitude: 0.03, phase: 0.0))
        constituents.append(TidalConstituent(id: "Ssa", speed: ConstituentSpeed.Ssa, amplitude: 0.02, phase: 0.0))

        return PortHarmonics(
            id: baseHarmonics.id,
            meanSeaLevel: Z0,
            constituents: constituents
        )
    }

    // MARK: - Méthodes d'analyse

    /// Calcule la phase de M2 à partir de l'heure de la première PM
    private func calculateM2Phase(from tides: [TideData]) -> Double {
        let highTides = tides.filter { $0.isHighTide }.sorted { $0.date < $1.date }
        guard let firstHigh = highTides.first else { return 0 }

        // Heure UTC de la première PM
        let calendar = Calendar(identifier: .gregorian)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let comp = utcCalendar.dateComponents([.hour, .minute], from: firstHigh.date)
        let hourFraction = Double(comp.hour ?? 0) + Double(comp.minute ?? 0) / 60.0

        // Phase = ω × t (modulo 360)
        // Le transit de la Lune est à 0°, la PM arrive avec un retard = la phase
        return AstronomicalArguments.normalize(ConstituentSpeed.M2 * hourFraction)
    }

    /// Estime le décalage de phase S2 par rapport à M2
    private func estimateS2PhaseOffset(from tides: [TideData]) -> Double {
        let highTides = tides.filter { $0.isHighTide }.sorted { $0.date < $1.date }
        guard highTides.count >= 4 else { return 0 }

        // Le décalage horaire moyen entre PM successives indique le battement M2/S2
        var intervals: [TimeInterval] = []
        for i in 1..<highTides.count {
            intervals.append(highTides[i].date.timeIntervalSince(highTides[i-1].date))
        }

        let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        // Période M2 = 12.42h, intervalle moyen dépend du cycle S2
        let deviation = (avgInterval / 3600.0 - 12.42) * ConstituentSpeed.S2

        return deviation
    }

    /// Calcule l'asymétrie marégraphique (indice d'inégalité diurne)
    private func calculateTidalAsymmetry(tides: [TideData]) -> Double {
        let highTides = tides.filter { $0.isHighTide }.sorted { $0.date < $1.date }
        guard highTides.count >= 4 else { return 0 }

        // Comparer les PM successives pour détecter l'inégalité diurne
        var diffs: [Double] = []
        for i in stride(from: 0, to: highTides.count - 1, by: 2) {
            if i + 1 < highTides.count {
                diffs.append(abs(highTides[i].height - highTides[i + 1].height))
            }
        }

        guard !diffs.isEmpty else { return 0 }
        let avgHigh = highTides.map(\.height).reduce(0, +) / Double(highTides.count)
        let avgDiff = diffs.reduce(0, +) / Double(diffs.count)

        return avgHigh > 0 ? avgDiff / avgHigh : 0
    }

    /// Calcule le ratio d'eaux peu profondes (asymétrie montant/descendant)
    private func calculateShallowWaterRatio(tides: [TideData]) -> Double {
        let sorted = tides.sorted { $0.date < $1.date }
        guard sorted.count >= 4 else { return 1.0 }

        var risingDurations: [TimeInterval] = []
        var fallingDurations: [TimeInterval] = []

        for i in 1..<sorted.count {
            let duration = sorted[i].date.timeIntervalSince(sorted[i-1].date)
            if sorted[i].isHighTide {
                // Montant : BM → PM
                risingDurations.append(duration)
            } else {
                // Descendant : PM → BM
                fallingDurations.append(duration)
            }
        }

        guard !risingDurations.isEmpty && !fallingDurations.isEmpty else { return 1.0 }

        let avgRising = risingDurations.reduce(0, +) / Double(risingDurations.count)
        let avgFalling = fallingDurations.reduce(0, +) / Double(fallingDurations.count)

        // Ratio > 1 = eaux peu profondes (montant plus rapide que descendant)
        return avgFalling > 0 ? max(1.0, avgRising / avgFalling) : 1.0
    }

    /// Affine la position d'un extremum par interpolation parabolique
    private func refineExtremum(
        p0: (date: Date, height: Double),
        p1: (date: Date, height: Double),
        p2: (date: Date, height: Double)
    ) -> (Date, Double) {
        // Interpolation parabolique pour trouver le vrai extremum
        let t0 = 0.0
        let t1 = p1.date.timeIntervalSince(p0.date)
        let t2 = p2.date.timeIntervalSince(p0.date)

        let h0 = p0.height, h1 = p1.height, h2 = p2.height

        // Formule du sommet de la parabole passant par les 3 points
        let denom = (t0 - t1) * (t0 - t2) * (t1 - t2)
        guard abs(denom) > 1e-10 else { return (p1.date, p1.height) }

        let a = (t2 * (h1 - h0) + t1 * (h0 - h2) + t0 * (h2 - h1)) / denom
        guard abs(a) > 1e-10 else { return (p1.date, p1.height) }

        let b = (t2 * t2 * (h0 - h1) + t1 * t1 * (h2 - h0) + t0 * t0 * (h1 - h2)) / denom

        // Sommet : t_ext = -b / (2a)
        let tExt = -b / (2 * a)

        // Vérifier que le résultat est dans l'intervalle
        guard tExt >= t0 && tExt <= t2 else { return (p1.date, p1.height) }

        let refinedDate = p0.date.addingTimeInterval(tExt)
        let refinedHeight = a * tExt * tExt + b * tExt + h0 // Évaluation du polynôme

        return (refinedDate, refinedHeight)
    }

    /// Estime le coefficient de marée pour une PM. `lowTideHeight` = BM adjacente si connue.
    private func estimateCoefficient(highTideHeight: Double, lowTideHeight: Double?, portId: String) -> Int? {
        guard let harmonics = bestHarmonics(for: portId) else { return nil }
        return Self.estimateCoefficient(highTideHeight: highTideHeight, lowTideHeight: lowTideHeight, harmonics: harmonics)
    }

    // MARK: - Coefficient de marée calibré (échelle SHOM)

    /// Ancrage coef-95 par port de RÉFÉRENCE = demi-marnage de VIVE-EAU MOYENNE (= coef 95),
    /// dérivé empiriquement d'1 an de prédictions (moyenne des pics de marnage). Clé : "BREST"
    /// pour les ports français (coef national), ou l'id du port pour les ports étrangers.
    private var coef95Anchor: [String: Double] = [:]

    /// Calcule (et cache) l'ancrage coef-95 de Brest = demi-marnage de VIVE-EAU MOYENNE,
    /// estimé comme la moyenne des PICS de marnage (max par fenêtre de 14,77 j = un cycle
    /// vive-eau/morte-eau, les vives-eaux survenant à la nouvelle ET à la pleine lune).
    /// La moyenne de la « moitié haute » sous-estimerait le pic (distribution en arcsinus
    /// du battement vive-eau → coefficients gonflés). Pur → exécutable hors MainActor.
    nonisolated static func computeSpringSemiRange(_ brest: PortHarmonics) -> Double {
        let M2 = brest.constituents.first { $0.id == "M2" }?.amplitude ?? 1.0
        let S2 = brest.constituents.first { $0.id == "S2" }?.amplitude ?? 0.3
        let fallback = M2 + S2
        let start = startOfYearUTCStatic(for: Date(timeIntervalSince1970: 1_577_836_800)) // 2020
        let year = computeExtrema(from: start, to: start.addingTimeInterval(370 * 86400),
                                  harmonics: brest, coefContext: nil)
        let windowSec = 14.765 * 86400.0   // demi-mois synodique : un pic de vive-eau par fenêtre
        var maxByWindow: [Int: Double] = [:]
        for i in year.indices where year[i].isHighTide {
            // Marnage MONTANT (PM − BM précédente), comme `shomCoefficient`.
            guard i - 1 >= 0, !year[i - 1].isHighTide else { continue }
            let semiRange = (year[i].height - year[i - 1].height) / 2.0
            let w = Int(year[i].date.timeIntervalSince(start) / windowSec)
            maxByWindow[w] = max(maxByWindow[w] ?? 0, semiRange)
        }
        guard maxByWindow.count > 4 else { return fallback }
        let peaks = Array(maxByWindow.values)
        return peaks.reduce(0, +) / Double(peaks.count)
    }

    /// Coefficient de marée calibré (échelle SHOM, vive-eau moyenne = 95).
    /// Affiché UNIQUEMENT pour les ports de MÉTROPOLE (référence = BREST → coefficient NATIONAL
    /// identique partout, validé EXACT contre le SHOM). Partout ailleurs — ports mondiaux ET
    /// outre-mer français — AUCUN coefficient : la notion est française/métropolitaine et nous ne
    /// l'affichons que là où nous en sommes certains (consigne « si pas sûr, pas de coef »).
    private func withCalibratedCoefficients(_ tides: [TideData], portId: String,
                                            from: Date, to: Date) -> [TideData] {
        guard isMetropolitanFrench(portId) else { return tides }
        guard let u95 = coef95Anchor[Self.coefficientReferencePortId], u95 > 0,
              let brest = harmonicsDB[Self.coefficientReferencePortId] else { return tides }
        let refTides = Self.computeExtrema(
            from: from.addingTimeInterval(-15 * 3600),
            to: to.addingTimeInterval(15 * 3600),
            harmonics: brest, coefContext: nil)
        return Self.applyNationalCoefficients(tides, brestTides: refTides, coef95SemiRange: u95)
    }

    /// Réécrit le coefficient de chaque PM à partir du marnage de Brest (convention SHOM).
    /// `coef95SemiRange` = demi-marnage de vive-eau moyenne de Brest (échelle : ce marnage = 95).
    nonisolated static func applyNationalCoefficients(_ tides: [TideData],
                                                      brestTides: [TideData],
                                                      coef95SemiRange: Double) -> [TideData] {
        guard coef95SemiRange > 0, !brestTides.isEmpty else { return tides }
        return tides.map { t in
            guard t.isHighTide,
                  let coef = shomCoefficient(at: t.date, brestTides: brestTides, brestUnit: coef95SemiRange)
            else { return t }
            return TideData(date: t.date, height: t.height, isHighTide: true, coefficient: coef)
        }
    }

    /// Coefficient SHOM (~20-120) pour la PM de Brest la plus proche de `date`.
    nonisolated static func shomCoefficient(at date: Date, brestTides: [TideData], brestUnit: Double) -> Int? {
        guard brestUnit > 0 else { return nil }
        var bestIdx = -1
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, t) in brestTides.enumerated() where t.isHighTide {
            let d = abs(t.date.timeIntervalSince(date))
            if d < bestDelta { bestDelta = d; bestIdx = i }
        }
        guard bestIdx >= 0 else { return nil }
        let pm = brestTides[bestIdx].height
        // Marnage MONTANT : PM − BM PRÉCÉDENTE (convention SHOM, validé contre les
        // coefficients publiés maree.info). Utiliser la plus basse des deux voisines
        // surestimait la marée du soir de +2-3 points.
        let bm: Double
        if bestIdx - 1 >= 0, !brestTides[bestIdx - 1].isHighTide {
            bm = brestTides[bestIdx - 1].height
        } else if bestIdx + 1 < brestTides.count, !brestTides[bestIdx + 1].isHighTide {
            bm = brestTides[bestIdx + 1].height   // repli : BM suivante (bord de fenêtre)
        } else {
            return nil
        }
        let semiRange = (pm - bm) / 2.0
        // 94.4 (et non 95) : la vive-eau moyenne SHOM (coef 95) est ~0,6 % SOUS le pic
        // de marnage moyen utilisé comme ancrage. Calé contre le SHOM (MAE ≈ 0,2 sur juin 2026).
        return max(20, min(120, Int((semiRange / brestUnit * 94.4).rounded())))
    }

    /// Cœur pur du calcul de coefficient (utilisable hors MainActor, p.ex. dans
    /// `computeExtrema` pour les prévisions étendues J8-J30).
    /// Utilise le DEMI-MARNAGE (PM − BM)/2 quand la BM adjacente est connue : cela annule
    /// le décalage saisonnier (Sa/Ssa) et l'asymétrie qui polluaient l'ancien (PM − Z₀).
    nonisolated static func estimateCoefficient(highTideHeight: Double, lowTideHeight: Double?, harmonics: PortHarmonics) -> Int? {
        let M2 = harmonics.constituents.first { $0.id == "M2" }?.amplitude ?? 1.0
        let S2 = harmonics.constituents.first { $0.id == "S2" }?.amplitude ?? 0.3
        let unit = M2 + S2  // semi-amplitude des vives-eaux moyennes ≈ coef 100

        guard unit > 0 else { return nil }

        // Le coefficient SHOM (20-120) mesure la modulation M2±S2 du cycle vives-eaux/mortes-eaux
        // (battement semi-diurne ~14,77 j). Il N'A AUCUN SENS pour un régime MIXTE/DIURNE où
        // K1/O1 dominent (facteur de forme F = (K1+O1)/(M2+S2) > 0,25, ex. San Francisco F≈0,84) :
        // la formule saturait à 120 tous les jours. → on ne l'affiche pas pour ces ports.
        let K1 = harmonics.constituents.first { $0.id == "K1" }?.amplitude ?? 0
        let O1 = harmonics.constituents.first { $0.id == "O1" }?.amplitude ?? 0
        if (K1 + O1) / unit > 0.25 { return nil }

        // Semi-amplitude du cycle : (PM − BM)/2 si BM connue, sinon repli (PM − Z₀).
        // Coef 100 = vives-eaux moyennes ; ~45 = mortes-eaux ; 120 = vives-eaux except.
        let amplitude = lowTideHeight.map { (highTideHeight - $0) / 2.0 }
            ?? (highTideHeight - harmonics.meanSeaLevel)
        let rawCoef = (amplitude / unit) * 100.0
        return max(20, min(120, Int(round(rawCoef))))
    }

    /// Régime SEMI-DIURNE ? Facteur de forme F = (K1+O1)/(M2+S2) ≤ 0,25. Le coefficient de
    /// marée (échelle SHOM) n'a de sens que dans ce régime ; on l'occulte ailleurs.
    nonisolated static func isSemidiurnal(_ h: PortHarmonics) -> Bool {
        let m2 = h.constituents.first { $0.id == "M2" }?.amplitude ?? 0
        let s2 = h.constituents.first { $0.id == "S2" }?.amplitude ?? 0
        let k1 = h.constituents.first { $0.id == "K1" }?.amplitude ?? 0
        let o1 = h.constituents.first { $0.id == "O1" }?.amplitude ?? 0
        let unit = m2 + s2
        guard unit > 0.05 else { return false }
        return (k1 + o1) / unit <= 0.25
    }

    // MARK: - Validation

    /// Valide la calibration en comparant les prédictions aux données observées
    private func validateCalibration(
        calibrated: PortHarmonics,
        observedTides: [TideData]
    ) -> PredictionAccuracy {
        guard observedTides.count >= 4 else { return .low }

        // Prédire les mêmes instants et comparer
        var errors: [Double] = []
        var timeErrors: [Double] = []

        for observed in observedTides {
            // Prédire la hauteur à l'heure observée
            if let predicted = predictHeightWithHarmonics(at: observed.date, harmonics: calibrated) {
                let heightError = abs(predicted - observed.height)
                errors.append(heightError)
            }
        }

        // Prédire les extrema et comparer les heures
        let sorted = observedTides.sorted { $0.date < $1.date }
        if let first = sorted.first, let last = sorted.last {
            let predicted = predictTidesWithHarmonics(
                from: first.date.addingTimeInterval(-3600),
                to: last.date.addingTimeInterval(3600),
                harmonics: calibrated
            )

            for obs in sorted {
                if let nearest = predicted.min(by: {
                    abs($0.date.timeIntervalSince(obs.date)) < abs($1.date.timeIntervalSince(obs.date))
                }) {
                    timeErrors.append(abs(nearest.date.timeIntervalSince(obs.date)) / 60.0) // En minutes
                }
            }
        }

        guard !errors.isEmpty else { return .low }

        let avgError = errors.reduce(0, +) / Double(errors.count)
        let avgTimeError = timeErrors.isEmpty ? 30.0 : timeErrors.reduce(0, +) / Double(timeErrors.count)

        // Classification de la précision
        if avgError < 0.10 && avgTimeError < 10 {
            return .veryHigh      // < 10cm et < 10min
        } else if avgError < 0.20 && avgTimeError < 15 {
            return .high          // < 20cm et < 15min
        } else if avgError < 0.35 && avgTimeError < 25 {
            return .medium        // < 35cm et < 25min
        } else {
            return .low
        }
    }

    /// Prédiction avec un jeu de constantes spécifique
    private func predictHeightWithHarmonics(at date: Date, harmonics: PortHarmonics) -> Double? {
        // ⚠️ V₀ à l'ÉPOQUE (voir predictHeight).
        let refDate = startOfYearUTC(for: date)
        let refAstro = AstronomicalArguments(date: refDate)
        let astro = AstronomicalArguments(date: date)
        let hours = date.timeIntervalSince(refDate) / 3600.0

        var height = harmonics.meanSeaLevel
        for constituent in harmonics.constituents {
            let f = astro.nodalF(for: constituent.id)
            let u = astro.nodalU(for: constituent.id)
            let V0 = refAstro.V0(for: constituent.id)
            height += constituent.contribution(hours: hours, nodalF: f, nodalU: u, V0: V0)
        }
        return height   // pas de clamp : cf. predictHeight (les BM sous le datum doivent rester)
    }

    /// Prédiction d'extrema avec un jeu de constantes spécifique
    private func predictTidesWithHarmonics(
        from startDate: Date, to endDate: Date, harmonics: PortHarmonics
    ) -> [TideData] {
        let step: TimeInterval = 180
        var heights: [(date: Date, height: Double)] = []
        var current = startDate

        while current <= endDate {
            if let h = predictHeightWithHarmonics(at: current, harmonics: harmonics) {
                heights.append((current, h))
            }
            current = current.addingTimeInterval(step)
        }

        guard heights.count >= 3 else { return [] }

        var tides: [TideData] = []
        for i in 1..<(heights.count - 1) {
            let prev = heights[i-1].height
            let curr = heights[i].height
            let next = heights[i+1].height

            if (curr > prev && curr > next) || (curr < prev && curr < next) {
                let isHigh = curr > prev && curr > next
                let (rDate, rHeight) = refineExtremum(p0: heights[i-1], p1: heights[i], p2: heights[i+1])

                if let last = tides.last, rDate.timeIntervalSince(last.date) < 3 * 3600 { continue }

                let prevLow = isHigh ? tides.last.flatMap({ $0.isHighTide ? nil : $0.height }) : nil
                tides.append(TideData(
                    date: rDate,
                    height: round(rHeight * 100) / 100,
                    isHighTide: isHigh,
                    coefficient: isHigh ? Self.estimateCoefficient(highTideHeight: rHeight, lowTideHeight: prevLow, harmonics: harmonics) : nil
                ))
            }
        }

        return tides.sorted { $0.date < $1.date }
    }

    // MARK: - Base de données harmoniques

    /// Retourne les meilleures constantes disponibles (calibrées > built-in)
    private func bestHarmonics(for portId: String) -> PortHarmonics? {
        return calibratedHarmonics[portId] ?? harmonicsDB[portId]
    }

    /// Génère des constantes par défaut à partir des données SHOM observées
    private func generateDefaultHarmonics(portId: String, fromTides tides: [TideData]) -> PortHarmonics {
        let highTides = tides.filter { $0.isHighTide }
        let lowTides = tides.filter { !$0.isHighTide }

        let avgHigh = highTides.isEmpty ? 4.0 : highTides.map(\.height).reduce(0, +) / Double(highTides.count)
        let avgLow = lowTides.isEmpty ? 1.5 : lowTides.map(\.height).reduce(0, +) / Double(lowTides.count)

        let Z0 = (avgHigh + avgLow) / 2.0
        let range = avgHigh - avgLow

        // Estimation simplifiée des constituants principaux
        return PortHarmonics(
            id: portId,
            meanSeaLevel: Z0,
            constituents: [
                TidalConstituent(id: "M2", speed: ConstituentSpeed.M2, amplitude: range * 0.46, phase: 0),
                TidalConstituent(id: "S2", speed: ConstituentSpeed.S2, amplitude: range * 0.15, phase: 30),
                TidalConstituent(id: "N2", speed: ConstituentSpeed.N2, amplitude: range * 0.09, phase: 340),
                TidalConstituent(id: "K1", speed: ConstituentSpeed.K1, amplitude: range * 0.06, phase: 90),
                TidalConstituent(id: "O1", speed: ConstituentSpeed.O1, amplitude: range * 0.04, phase: 60),
            ]
        )
    }

    /// Charge les constantes harmoniques intégrées (ports principaux français)
    /// ⚠️ SUPPRIMÉ : les harmoniques « built-in » étaient des approximations manuelles
    /// (phases inexactes → horaires décalés de ~2-3 h). Elles court-circuitaient le
    /// rattachement TICON au lancement et empoisonnaient le cache. Les ports français
    /// sont désormais servis EXCLUSIVEMENT par PortCatalog.linkFrenchHarmonicsInBackground.
    private func loadBuiltInHarmonics() {
        // no-op — conservé pour documenter l'historique.
    }

    // MARK: - Persistance des données calibrées

    private let calibrationKey = "calibratedTideHarmonics"

    private func saveCalibratedHarmonics() {
        do {
            let data = try JSONEncoder().encode(Array(calibratedHarmonics.values))
            UserDefaults.standard.set(data, forKey: calibrationKey)
        } catch {
            appLogger.error("[HarmonicEngine] Erreur sauvegarde calibration: \(error)")
        }
    }

    private func loadCalibratedHarmonics() {
        // ⚠️ NE PLUS CHARGER les calibrations persistées : elles venaient de l'ancienne voie
        // RÉSEAU (NOAA/SHOM API), aujourd'hui SUPPRIMÉE (app 100 % offline) et `calibrate`/
        // `deepCalibrate` n'ont plus aucun appelant. Stockées dans une AUTRE convention de datum,
        // elles GONFLAIENT les hauteurs et faussaient le régime (ex. San Francisco : 4,45 m au
        // lieu de ~3 m + un coefficient SHOM affiché alors que SF est à marée mixte). Le moteur
        // s'appuie désormais UNIQUEMENT sur les harmoniques embarquées (harmonicsDB, validées
        // au backtest). On PURGE donc tout calibrage hérité et on n'en recharge aucun.
        calibratedHarmonics.removeAll()
        UserDefaults.standard.removeObject(forKey: calibrationKey)
    }

    // MARK: - Utilitaires

    /// Début de l'année UTC pour une date donnée
    private func startOfYearUTC(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let year = calendar.component(.year, from: date)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 0))!
    }

    /// Vérifie si un port a des constantes harmoniques (built-in ou calibrées)
    func hasHarmonics(for portId: String) -> Bool {
        return calibratedHarmonics[portId] != nil || harmonicsDB[portId] != nil
    }

    /// Vérifie si un port a été calibré
    func isCalibrated(for portId: String) -> Bool {
        return calibratedHarmonics[portId] != nil
    }

    /// Nombre de constituants utilisés pour un port
    func constituentCount(for portId: String) -> Int {
        return bestHarmonics(for: portId)?.constituents.count ?? 0
    }

    /// Enregistre des constantes harmoniques externes (NOAA, TICON) dans la base built-in
    func registerHarmonics(_ harmonics: PortHarmonics) {
        harmonicsDB[harmonics.id] = harmonics
    }

    /// Ports dont le Z₀ a déjà été résolu (ou n'a pas besoin de l'être).
    private var datumResolved: Set<String> = []

    /// Dérive PARESSEUSEMENT le zéro hydrographique (Z₀) d'un port NOAA/TICON dont les
    /// JSON bundlés ne fournissent qu'un niveau moyen nul. Sans cela, `predictHeight`
    /// oscille autour de 0 et clampe toutes les basses mers à 0,00 m (hauteurs fausses
    /// pour tous les ports internationaux). Idempotent ; le calcul lourd (~1 an de
    /// prédiction horaire) tourne hors MainActor et n'est payé qu'une fois par port,
    /// au moment de sa première consultation.
    func ensureChartDatum(for portId: String) async {
        guard !datumResolved.contains(portId),
              let h = harmonicsDB[portId],
              h.meanSeaLevel == 0,
              h.constituents.contains(where: { $0.speed > 10 }) // vraie marée diurne/semi-diurne
        else { return }

        datumResolved.insert(portId)   // verrou : évite les dérivations concurrentes
        let constituents = h.constituents
        // Même passe hors-main : Z₀ (zéro hydro) ET ancrage coef-95 du port (le Z₀ ne change
        // pas le marnage, donc l'ancrage est correct quel que soit Z₀).
        let (z0, anchor) = await Task.detached(priority: .userInitiated) { () -> (Double, Double) in
            let z = HarmonicTideEngine.chartDatumZ0(constituents: constituents)
            let a = HarmonicTideEngine.computeSpringSemiRange(
                PortHarmonics(id: portId, meanSeaLevel: 0, constituents: constituents))
            return (z, a)
        }.value

        guard let current = harmonicsDB[portId] else { return }
        if z0 > 0 {
            harmonicsDB[portId] = PortHarmonics(
                id: current.id, meanSeaLevel: z0, constituents: current.constituents)
        }
        if anchor > 0 { coef95Anchor[portId] = anchor }   // coef calibré pour ce port étranger
        predictionCache.removeAll()    // les prédictions cachées partaient d'un Z₀ nul / sans coef
        objectWillChange.send()
    }

    /// Variante SYNCHRONE de `ensureChartDatum`, exécutée AVANT toute prédiction sur le
    /// thread courant. Indispensable : `predictTides` peut tourner AVANT que la version async
    /// n'ait patché le Z₀ (course via le `Task.detached`). Avec Z₀ = 0, les basses mers
    /// passent SOUS le zéro hydrographique, sont écrêtées à 0 par `max(0, …)` dans
    /// `predictHeight`, le plancher devient plat → aucun minimum local → les BASSES MERS
    /// DISPARAISSENT (port mondial affichant 2 PM et aucune BM, ex. Fenit/Ballycotton).
    /// Garde sur `meanSeaLevel == 0` (et NON sur `datumResolved`) → robuste même si la version
    /// async a déjà posé le verrou sans avoir fini de patcher. Idempotent, ~1 fois/port.
    private func ensureChartDatumSync(for portId: String) {
        guard let h = harmonicsDB[portId],
              h.meanSeaLevel == 0,
              h.constituents.contains(where: { $0.speed > 10 }) // vraie marée diurne/semi-diurne
        else { return }
        datumResolved.insert(portId)   // évite une dérivation async redondante ensuite
        let z0 = HarmonicTideEngine.chartDatumZ0(constituents: h.constituents)
        let anchor = HarmonicTideEngine.computeSpringSemiRange(
            PortHarmonics(id: portId, meanSeaLevel: 0, constituents: h.constituents))
        if z0 > 0 {
            harmonicsDB[portId] = PortHarmonics(id: h.id, meanSeaLevel: z0, constituents: h.constituents)
            predictionCache.removeAll()   // purge des prédictions calculées avec Z₀ = 0
        }
        if anchor > 0 { coef95Anchor[portId] = anchor }
    }

    // MARK: - Recalage fin temporel (Open-Meteo)

    /// Décalage temporel fin par port (s), issu du recalage vs extrema Open-Meteo.
    /// Réservé aux ports rattachés LOIN de leur station TICON.
    private var timeOffsets: [String: TimeInterval] = [:]

    func registerTimeOffset(_ seconds: TimeInterval, for portId: String) {
        timeOffsets[portId] = seconds
        predictionCache.removeAll()   // les prédictions cachées ne portent pas l'offset
    }

    func timeOffset(for portId: String) -> TimeInterval { timeOffsets[portId] ?? 0 }

    /// Applique l'offset fin d'un port à une liste de marées prédites.
    private func applyTimeOffset(_ tides: [TideData], portId: String) -> [TideData] {
        guard let off = timeOffsets[portId], off != 0 else { return tides }
        return tides.map {
            TideData(date: $0.date.addingTimeInterval(off), height: $0.height,
                     isHighTide: $0.isHighTide, coefficient: $0.coefficient)
        }
    }

    /// Charge en masse des harmoniques depuis un fichier JSON bundlé
    func loadBundledHarmonics(from jsonData: Data) {
        do {
            let harmonicsList = try JSONDecoder().decode([PortHarmonics].self, from: jsonData)
            for h in harmonicsList {
                harmonicsDB[h.id] = h
            }
            appLogger.info("[HarmonicEngine] \(harmonicsList.count) harmoniques mondiales chargées")
        } catch {
            appLogger.error("[HarmonicEngine] Erreur chargement harmoniques bundlées: \(error)")
        }
    }

    /// Réinitialise le calibrage d'un port
    func resetCalibration(for portId: String) {
        calibratedHarmonics.removeValue(forKey: portId)
        saveCalibratedHarmonics()
        predictionAccuracy = harmonicsDB[portId] != nil ? .medium : .uncalibrated
    }

    /// Purge TOUTES les calibrations persistées (migration v3). Les calibrations de
    /// l'époque SHOM ont été ajustées avec l'ancienne formule V₀ buggée : `bestHarmonics`
    /// les préférait aux harmoniques TICON fraîches → horaires décalés de plusieurs heures.
    func clearAllCalibrations() {
        calibratedHarmonics.removeAll()
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        appLogger.info("[HarmonicEngine] Calibrations héritées purgées (migration v3)")
    }

    // MARK: - Recalibrage profond avec données maree.info

    /// Recalibre les constantes harmoniques en utilisant les données de maree.info
    /// Cette méthode est beaucoup plus précise que le calibrage SHOM seul car elle
    /// dispose de données sur une plus longue période (plusieurs semaines/mois),
    /// permettant de séparer correctement les constituants proches en fréquence.
    ///
    /// Le principe : avec 7 jours de données SHOM, on ne peut pas distinguer M2 de N2
    /// (battement de 27.5 jours) ni S2 de K2 (battement de 182.6 jours).
    /// Avec 30+ jours de maree.info, on résout ces ambiguïtés.
    func deepCalibrate(portId: String, referenceTides: [TideData]) {
        guard referenceTides.count >= 20 else { return } // Min ~5 jours

        predictionAccuracy = .calibrating

        // Séparer PM et BM
        let highTides = referenceTides.filter { $0.isHighTide }.sorted { $0.date < $1.date }
        let lowTides = referenceTides.filter { !$0.isHighTide }.sorted { $0.date < $1.date }
        let allSorted = referenceTides.sorted { $0.date < $1.date }

        guard highTides.count >= 10 && lowTides.count >= 10 else {
            // Pas assez de données, utiliser le calibrage standard
            calibrate(portId: portId, shomTides: referenceTides)
            return
        }

        // Étape 1 : Niveau moyen Z₀ précis
        let allHeights = allSorted.map(\.height)
        let Z0 = allHeights.reduce(0, +) / Double(allHeights.count)

        // Étape 2 : Analyse des amplitudes par enveloppe
        let avgHigh = highTides.map(\.height).reduce(0, +) / Double(highTides.count)
        let avgLow = lowTides.map(\.height).reduce(0, +) / Double(lowTides.count)
        let maxHigh = highTides.map(\.height).max() ?? avgHigh
        let minHigh = highTides.map(\.height).min() ?? avgHigh
        let maxLow = lowTides.map(\.height).max() ?? avgLow
        let minLow = lowTides.map(\.height).min() ?? avgLow

        let maxRange = maxHigh - minLow
        let minRange = minHigh - maxLow

        // Étape 3 : Extraction des constituants par analyse d'enveloppe

        // M2 + S2 = demi marnage max (vives-eaux)
        // M2 - S2 = demi marnage min (mortes-eaux)
        // => M2 = (maxRange + minRange) / 4
        // => S2 = (maxRange - minRange) / 4
        let M2_amp = (maxRange + max(0, minRange)) / 4.0
        let S2_amp = max(0.01, (maxRange - max(0, minRange)) / 4.0)

        // N2 : modulation sur ~27.5 jours, visible si on a assez de données
        // L'enveloppe des PM varie : maxHigh - avgHigh ≈ S2 + N2
        // avgHigh - minHigh ≈ S2 - N2 (approx)
        let highEnvelopeUp = maxHigh - avgHigh
        let highEnvelopeDown = avgHigh - minHigh
        let N2_amp: Double
        if highTides.count >= 20 {
            // Avec assez de données, on peut estimer N2
            N2_amp = max(0.01, (highEnvelopeUp - S2_amp + highEnvelopeDown - S2_amp) / 4.0)
        } else {
            N2_amp = M2_amp * 0.19 // Ratio standard
        }

        // K2 : modulation semi-annuelle, ~27% de S2
        let K2_amp = S2_amp * 0.27

        // Étape 4 : Constituants diurnes par analyse de l'inégalité diurne
        // Comparer les PM consécutives d'une même journée
        var diurnalDiffs: [Double] = []
        for i in stride(from: 0, to: highTides.count - 1, by: 1) {
            let gap = highTides[i + 1].date.timeIntervalSince(highTides[i].date)
            if gap < 16 * 3600 { // Deux PM dans la même journée (~12h d'écart)
                diurnalDiffs.append(abs(highTides[i + 1].height - highTides[i].height))
            }
        }
        let avgDiurnalDiff = diurnalDiffs.isEmpty ? 0 : diurnalDiffs.reduce(0, +) / Double(diurnalDiffs.count)

        // K1 + O1 ≈ inégalité diurne / 2
        let K1_amp = max(0.01, avgDiurnalDiff / 4.0 * 1.5) // K1 dominant
        let O1_amp = K1_amp * 0.75
        let P1_amp = K1_amp * 0.33
        let Q1_amp = O1_amp * 0.19

        // Étape 5 : Phase M2 par minimisation d'erreur
        // Tester plusieurs phases et garder celle qui minimise l'erreur
        let M2_phase = optimizeM2Phase(
            highTides: highTides,
            lowTides: lowTides,
            Z0: Z0,
            M2_amp: M2_amp,
            S2_amp: S2_amp
        )

        // Phases des autres constituants par rapport à M2
        let S2_phase = optimizeS2Phase(
            highTides: highTides,
            Z0: Z0,
            M2_amp: M2_amp,
            M2_phase: M2_phase,
            S2_amp: S2_amp
        )

        let N2_phase = M2_phase - 20.0
        let K2_phase = S2_phase + 2.0
        let K1_phase = M2_phase / 2.0 + 90.0
        let O1_phase = M2_phase / 2.0 - 30.0
        let P1_phase = K1_phase - 2.0
        let Q1_phase = O1_phase - 20.0

        // Étape 6 : Quart-diurnes (eaux peu profondes)
        let shallowRatio = calculateShallowWaterRatio(tides: allSorted)
        let M4_amp = M2_amp * 0.04 * shallowRatio
        let MS4_amp = M4_amp * 0.4
        let M4_phase = 2.0 * M2_phase + 15.0
        let MS4_phase = M2_phase + S2_phase + 10.0

        // Étape 7 : Constituants mineurs
        let MU2_amp = M2_amp * 0.025
        let NU2_amp = N2_amp * 0.19
        let L2_amp = M2_amp * 0.03
        let _2N2_amp = N2_amp * 0.13
        let T2_amp = S2_amp * 0.06
        let J1_amp = K1_amp * 0.07
        let M6_amp = M2_amp * 0.01 * shallowRatio

        // Construire les constituants
        var constituents: [TidalConstituent] = [
            TidalConstituent(id: "M2",  speed: ConstituentSpeed.M2,  amplitude: M2_amp,  phase: M2_phase),
            TidalConstituent(id: "S2",  speed: ConstituentSpeed.S2,  amplitude: S2_amp,  phase: S2_phase),
            TidalConstituent(id: "N2",  speed: ConstituentSpeed.N2,  amplitude: N2_amp,  phase: N2_phase),
            TidalConstituent(id: "K2",  speed: ConstituentSpeed.K2,  amplitude: K2_amp,  phase: K2_phase),
            TidalConstituent(id: "K1",  speed: ConstituentSpeed.K1,  amplitude: K1_amp,  phase: K1_phase),
            TidalConstituent(id: "O1",  speed: ConstituentSpeed.O1,  amplitude: O1_amp,  phase: O1_phase),
            TidalConstituent(id: "P1",  speed: ConstituentSpeed.P1,  amplitude: P1_amp,  phase: P1_phase),
            TidalConstituent(id: "Q1",  speed: ConstituentSpeed.Q1,  amplitude: Q1_amp,  phase: Q1_phase),
            TidalConstituent(id: "M4",  speed: ConstituentSpeed.M4,  amplitude: M4_amp,  phase: M4_phase),
            TidalConstituent(id: "MS4", speed: ConstituentSpeed.MS4, amplitude: MS4_amp, phase: MS4_phase),
        ]

        // Ajouter mineurs si significatifs
        if _2N2_amp > 0.01 {
            constituents.append(TidalConstituent(id: "2N2", speed: ConstituentSpeed._2N2, amplitude: _2N2_amp, phase: N2_phase - 20.0))
        }
        if MU2_amp > 0.01 {
            constituents.append(TidalConstituent(id: "MU2", speed: ConstituentSpeed.MU2, amplitude: MU2_amp, phase: M2_phase + 180.0))
        }
        if NU2_amp > 0.01 {
            constituents.append(TidalConstituent(id: "NU2", speed: ConstituentSpeed.NU2, amplitude: NU2_amp, phase: N2_phase + 5.0))
        }
        if L2_amp > 0.01 {
            constituents.append(TidalConstituent(id: "L2", speed: ConstituentSpeed.L2, amplitude: L2_amp, phase: M2_phase + 180.0))
        }
        if T2_amp > 0.01 {
            constituents.append(TidalConstituent(id: "T2", speed: ConstituentSpeed.T2, amplitude: T2_amp, phase: S2_phase - 5.0))
        }
        if J1_amp > 0.01 {
            constituents.append(TidalConstituent(id: "J1", speed: ConstituentSpeed.J1, amplitude: J1_amp, phase: K1_phase + 20.0))
        }
        if M6_amp > 0.005 {
            constituents.append(TidalConstituent(id: "M6", speed: ConstituentSpeed.M6, amplitude: M6_amp, phase: 3.0 * M2_phase))
        }

        // Longue période
        constituents.append(TidalConstituent(id: "Sa", speed: ConstituentSpeed.Sa, amplitude: 0.03, phase: 0.0))
        constituents.append(TidalConstituent(id: "Ssa", speed: ConstituentSpeed.Ssa, amplitude: 0.02, phase: 0.0))

        let calibrated = PortHarmonics(
            id: portId,
            meanSeaLevel: Z0,
            constituents: constituents
        )

        // Étape 8 : Validation croisée
        let accuracy = validateCalibration(calibrated: calibrated, observedTides: referenceTides)

        // Sauvegarder seulement si c'est mieux que l'existant
        let currentAccuracy = predictionAccuracy
        let isImprovement = accuracyRank(accuracy) >= accuracyRank(currentAccuracy)

        if isImprovement {
            calibratedHarmonics[portId] = calibrated
            saveCalibratedHarmonics()
            predictionAccuracy = accuracy
            predictionCache.removeAll() // Invalider le cache
            appLogger.info("[HarmonicEngine] Recalibrage profond réussi pour \(portId): \(accuracy.rawValue) (\(constituents.count) constituants)")
        } else {
            appLogger.info("[HarmonicEngine] Recalibrage non améliorant pour \(portId), conserve l'existant")
            predictionAccuracy = currentAccuracy
        }
    }

    /// Optimise la phase de M2 par balayage et minimisation d'erreur
    private func optimizeM2Phase(
        highTides: [TideData],
        lowTides: [TideData],
        Z0: Double,
        M2_amp: Double,
        S2_amp: Double
    ) -> Double {
        var bestPhase = 0.0
        var bestError = Double.infinity

        // Balayer les phases de 0 à 360° par pas de 2°
        for phaseStep in stride(from: 0.0, to: 360.0, by: 2.0) {
            var totalError = 0.0

            // Évaluer l'erreur sur les PM
            for ht in highTides.prefix(20) {
                let astro = AstronomicalArguments(date: ht.date)
                let refDate = startOfYearUTC(for: ht.date)
                let hours = ht.date.timeIntervalSince(refDate) / 3600.0

                let f_M2 = astro.nodalF(for: "M2")
                let u_M2 = astro.nodalU(for: "M2")
                let V0_M2 = astro.V0(for: "M2")
                let f_S2 = astro.nodalF(for: "S2")
                let u_S2 = astro.nodalU(for: "S2")
                let V0_S2 = astro.V0(for: "S2")

                let predicted = Z0
                    + f_M2 * M2_amp * cos((V0_M2 + ConstituentSpeed.M2 * hours + u_M2 - phaseStep) * .pi / 180.0)
                    + f_S2 * S2_amp * cos((V0_S2 + ConstituentSpeed.S2 * hours + u_S2 - (phaseStep + 30.0)) * .pi / 180.0)

                totalError += (predicted - ht.height) * (predicted - ht.height)
            }

            // Évaluer aussi sur les BM
            for lt in lowTides.prefix(20) {
                let astro = AstronomicalArguments(date: lt.date)
                let refDate = startOfYearUTC(for: lt.date)
                let hours = lt.date.timeIntervalSince(refDate) / 3600.0

                let f_M2 = astro.nodalF(for: "M2")
                let u_M2 = astro.nodalU(for: "M2")
                let V0_M2 = astro.V0(for: "M2")

                let predicted = Z0
                    + f_M2 * M2_amp * cos((V0_M2 + ConstituentSpeed.M2 * hours + u_M2 - phaseStep) * .pi / 180.0)

                totalError += (predicted - lt.height) * (predicted - lt.height)
            }

            if totalError < bestError {
                bestError = totalError
                bestPhase = phaseStep
            }
        }

        // Affinage fin (pas de 0.5°)
        let fineStart = bestPhase - 3.0
        let fineEnd = bestPhase + 3.0
        for phaseStep in stride(from: fineStart, to: fineEnd, by: 0.5) {
            var totalError = 0.0

            for ht in highTides.prefix(20) {
                let astro = AstronomicalArguments(date: ht.date)
                let refDate = startOfYearUTC(for: ht.date)
                let hours = ht.date.timeIntervalSince(refDate) / 3600.0

                let f_M2 = astro.nodalF(for: "M2")
                let u_M2 = astro.nodalU(for: "M2")
                let V0_M2 = astro.V0(for: "M2")

                let predicted = Z0
                    + f_M2 * M2_amp * cos((V0_M2 + ConstituentSpeed.M2 * hours + u_M2 - phaseStep) * .pi / 180.0)

                totalError += (predicted - ht.height) * (predicted - ht.height)
            }

            if totalError < bestError {
                bestError = totalError
                bestPhase = phaseStep
            }
        }

        return AstronomicalArguments.normalize(bestPhase)
    }

    /// Optimise la phase de S2 par rapport à M2 calibré
    private func optimizeS2Phase(
        highTides: [TideData],
        Z0: Double,
        M2_amp: Double,
        M2_phase: Double,
        S2_amp: Double
    ) -> Double {
        var bestPhase = M2_phase + 30.0
        var bestError = Double.infinity

        for phaseStep in stride(from: 0.0, to: 360.0, by: 3.0) {
            var totalError = 0.0

            for ht in highTides.prefix(20) {
                let astro = AstronomicalArguments(date: ht.date)
                let refDate = startOfYearUTC(for: ht.date)
                let hours = ht.date.timeIntervalSince(refDate) / 3600.0

                let f_M2 = astro.nodalF(for: "M2")
                let u_M2 = astro.nodalU(for: "M2")
                let V0_M2 = astro.V0(for: "M2")
                let f_S2 = astro.nodalF(for: "S2")
                let u_S2 = astro.nodalU(for: "S2")
                let V0_S2 = astro.V0(for: "S2")

                let predicted = Z0
                    + f_M2 * M2_amp * cos((V0_M2 + ConstituentSpeed.M2 * hours + u_M2 - M2_phase) * .pi / 180.0)
                    + f_S2 * S2_amp * cos((V0_S2 + ConstituentSpeed.S2 * hours + u_S2 - phaseStep) * .pi / 180.0)

                totalError += (predicted - ht.height) * (predicted - ht.height)
            }

            if totalError < bestError {
                bestError = totalError
                bestPhase = phaseStep
            }
        }

        return AstronomicalArguments.normalize(bestPhase)
    }

    /// Classement numérique des niveaux de précision
    private func accuracyRank(_ accuracy: PredictionAccuracy) -> Int {
        switch accuracy {
        case .uncalibrated: return 0
        case .calibrating: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .veryHigh: return 4
        }
    }
}
