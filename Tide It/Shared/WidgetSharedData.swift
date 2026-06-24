//
//  WidgetSharedData.swift
//  Tide It
//
//  Données partagées entre l'app et le widget (App Group)
//

import Foundation

/// Point de marée léger pour résolution autonome widget/watch
struct SimpleTide: Codable, Equatable, Sendable {
    let date: Date
    let height: Double
    let isHigh: Bool
    let coefficient: Int?
}

/// Données affichées dans le widget - encodées par l'app, lues par le widget
struct WidgetSharedData: Codable, Sendable {
    let portName: String
    let nextTideDate: Date
    let nextTideHeight: Double
    let nextTideIsHigh: Bool
    let nextTideCoef: Int?
    let currentHeight: Double
    let trend: String
    let updatedAt: Date

    // Coefficient du jour (toujours rempli si disponible, indépendant de la marée)
    let todayCoef: Int?

    // Marée précédente (pour interpolation côté widget)
    let previousTideDate: Date?
    let previousTideHeight: Double?

    // 2ème marée (celle après la prochaine)
    let secondTideDate: Date?
    let secondTideHeight: Double?
    let secondTideIsHigh: Bool?
    let secondTideCoef: Int?

    // Tableau complet des marées (7 jours) pour résolution autonome
    let allTides: [SimpleTide]

    // Fuseau horaire du port → le widget/la watch affichent les heures en LOCAL du port
    let timeZoneIdentifier: String?

    // Système d'unités (rawValue : "metric"/"imperial") → la Watch n'a pas accès aux
    // réglages iPhone (App Groups non partagés entre appareils), on le transporte donc ici.
    let measureSystemRaw: String?

    // Unité de vent réglée (rawValue : "km/h"/"kn"/"m/s"/"mph") → idem, transportée
    // pour que la Watch affiche le vent observé dans la bonne unité.
    let windSpeedUnitRaw: String?

    // Lever / coucher du soleil du jour au port (absolus) → affichés sur l'app/complication Watch.
    let sunrise: Date?
    let sunset: Date?

    // Vent observé temps réel (balise anémomètre la plus proche). Tous optionnels :
    // absents si pas de balise proche OU si l'utilisateur n'est pas premium.
    let observedWindKmh: Double?
    let observedWindGustKmh: Double?
    let observedWindDirDeg: Double?
    let observedWindStation: String?
    let observedWindDistanceKm: Double?
    let observedWindDate: Date?
    /// true = une balise existe mais le vent temps réel est réservé au premium (→ upsell widget).
    let realtimeWindLocked: Bool?

    // Vent PRÉVU (Open-Meteo) le plus proche de maintenant — repli du widget vent quand aucune
    // balise temps réel n'est disponible (sinon le widget restait « aveugle »).
    let forecastWindKmh: Double?
    let forecastWindGustKmh: Double?
    let forecastWindDirDeg: Double?
    let forecastWindConfidence: Double?   // 0–1 : accord entre modèles AROME/ICON/GFS

    /// Identité géographique du port (rétro-compatibles, optionnels) → permettent au
    /// background refresh de reprogrammer les alertes AVEC le bon port et la bonne
    /// localisation (sinon les notifs partaient sur le mauvais port et les alertes soleil
    /// étaient effacées toutes les 30 min).
    let portId: String?
    let latitude: Double?
    let longitude: Double?

    // MARK: - Surf (spots de surf UNIQUEMENT — tout nil pour un port classique)
    /// true = le port suivi est un spot de surf du catalogue → le widget surf affiche des données.
    let isSurfSpot: Bool?
    /// Houle DOMINANTE choisie par énergie (Hs²·T). Provenance = modèle large (~25 km, offshore),
    /// pas spot-grade — honnête, jamais 0 si la donnée manque (les champs restent nil).
    let surfSwellHeightM: Double?
    let surfSwellPeriodS: Double?
    let surfSwellDirectionDeg: Double?     // deg, provenance (FROM)
    /// Verdict « coup d'œil » = SurfGrade.rawValue (flat / clean / firing / oversized / unknown).
    let surfGradeRaw: String?

    /// Fuseau du port (replié sur le fuseau de l'appareil si absent — anciennes données).
    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
    }

    init(portName: String, nextTideDate: Date, nextTideHeight: Double, nextTideIsHigh: Bool,
         nextTideCoef: Int?, currentHeight: Double, trend: String, updatedAt: Date,
         todayCoef: Int? = nil,
         previousTideDate: Date? = nil, previousTideHeight: Double? = nil,
         secondTideDate: Date? = nil, secondTideHeight: Double? = nil, secondTideIsHigh: Bool? = nil,
         secondTideCoef: Int? = nil,
         allTides: [SimpleTide] = [],
         timeZoneIdentifier: String? = nil,
         measureSystemRaw: String? = nil,
         windSpeedUnitRaw: String? = nil,
         sunrise: Date? = nil,
         sunset: Date? = nil,
         observedWindKmh: Double? = nil,
         observedWindGustKmh: Double? = nil,
         observedWindDirDeg: Double? = nil,
         observedWindStation: String? = nil,
         observedWindDistanceKm: Double? = nil,
         observedWindDate: Date? = nil,
         realtimeWindLocked: Bool? = nil,
         forecastWindKmh: Double? = nil,
         forecastWindGustKmh: Double? = nil,
         forecastWindDirDeg: Double? = nil,
         forecastWindConfidence: Double? = nil,
         portId: String? = nil,
         latitude: Double? = nil,
         longitude: Double? = nil,
         isSurfSpot: Bool? = nil,
         surfSwellHeightM: Double? = nil,
         surfSwellPeriodS: Double? = nil,
         surfSwellDirectionDeg: Double? = nil,
         surfGradeRaw: String? = nil) {
        self.isSurfSpot = isSurfSpot
        self.surfSwellHeightM = surfSwellHeightM
        self.surfSwellPeriodS = surfSwellPeriodS
        self.surfSwellDirectionDeg = surfSwellDirectionDeg
        self.surfGradeRaw = surfGradeRaw
        self.forecastWindKmh = forecastWindKmh
        self.forecastWindGustKmh = forecastWindGustKmh
        self.forecastWindDirDeg = forecastWindDirDeg
        self.forecastWindConfidence = forecastWindConfidence
        self.portId = portId
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.measureSystemRaw = measureSystemRaw
        self.windSpeedUnitRaw = windSpeedUnitRaw
        self.sunrise = sunrise
        self.sunset = sunset
        self.observedWindKmh = observedWindKmh
        self.observedWindGustKmh = observedWindGustKmh
        self.observedWindDirDeg = observedWindDirDeg
        self.observedWindStation = observedWindStation
        self.observedWindDistanceKm = observedWindDistanceKm
        self.observedWindDate = observedWindDate
        self.realtimeWindLocked = realtimeWindLocked
        self.portName = portName
        self.nextTideDate = nextTideDate
        self.nextTideHeight = nextTideHeight
        self.nextTideIsHigh = nextTideIsHigh
        self.nextTideCoef = nextTideCoef
        self.currentHeight = currentHeight
        self.trend = trend
        self.updatedAt = updatedAt
        self.todayCoef = todayCoef
        self.previousTideDate = previousTideDate
        self.previousTideHeight = previousTideHeight
        self.secondTideDate = secondTideDate
        self.secondTideHeight = secondTideHeight
        self.secondTideIsHigh = secondTideIsHigh
        self.secondTideCoef = secondTideCoef
        self.allTides = allTides
    }

    // Décodage rétrocompatible : allTides peut être absent dans les anciennes données
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portName = try c.decode(String.self, forKey: .portName)
        nextTideDate = try c.decode(Date.self, forKey: .nextTideDate)
        nextTideHeight = try c.decode(Double.self, forKey: .nextTideHeight)
        nextTideIsHigh = try c.decode(Bool.self, forKey: .nextTideIsHigh)
        nextTideCoef = try c.decodeIfPresent(Int.self, forKey: .nextTideCoef)
        currentHeight = try c.decode(Double.self, forKey: .currentHeight)
        trend = try c.decode(String.self, forKey: .trend)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        todayCoef = try c.decodeIfPresent(Int.self, forKey: .todayCoef)
        previousTideDate = try c.decodeIfPresent(Date.self, forKey: .previousTideDate)
        previousTideHeight = try c.decodeIfPresent(Double.self, forKey: .previousTideHeight)
        secondTideDate = try c.decodeIfPresent(Date.self, forKey: .secondTideDate)
        secondTideHeight = try c.decodeIfPresent(Double.self, forKey: .secondTideHeight)
        secondTideIsHigh = try c.decodeIfPresent(Bool.self, forKey: .secondTideIsHigh)
        secondTideCoef = try c.decodeIfPresent(Int.self, forKey: .secondTideCoef)
        allTides = (try? c.decodeIfPresent([SimpleTide].self, forKey: .allTides)) ?? []
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        measureSystemRaw = try c.decodeIfPresent(String.self, forKey: .measureSystemRaw)
        windSpeedUnitRaw = try c.decodeIfPresent(String.self, forKey: .windSpeedUnitRaw)
        sunrise = try c.decodeIfPresent(Date.self, forKey: .sunrise)
        sunset = try c.decodeIfPresent(Date.self, forKey: .sunset)
        observedWindKmh = try c.decodeIfPresent(Double.self, forKey: .observedWindKmh)
        observedWindGustKmh = try c.decodeIfPresent(Double.self, forKey: .observedWindGustKmh)
        observedWindDirDeg = try c.decodeIfPresent(Double.self, forKey: .observedWindDirDeg)
        observedWindStation = try c.decodeIfPresent(String.self, forKey: .observedWindStation)
        observedWindDistanceKm = try c.decodeIfPresent(Double.self, forKey: .observedWindDistanceKm)
        observedWindDate = try c.decodeIfPresent(Date.self, forKey: .observedWindDate)
        realtimeWindLocked = try c.decodeIfPresent(Bool.self, forKey: .realtimeWindLocked)
        forecastWindKmh = try c.decodeIfPresent(Double.self, forKey: .forecastWindKmh)
        forecastWindGustKmh = try c.decodeIfPresent(Double.self, forKey: .forecastWindGustKmh)
        forecastWindDirDeg = try c.decodeIfPresent(Double.self, forKey: .forecastWindDirDeg)
        forecastWindConfidence = try c.decodeIfPresent(Double.self, forKey: .forecastWindConfidence)
        portId = try c.decodeIfPresent(String.self, forKey: .portId)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        isSurfSpot = try c.decodeIfPresent(Bool.self, forKey: .isSurfSpot)
        surfSwellHeightM = try c.decodeIfPresent(Double.self, forKey: .surfSwellHeightM)
        surfSwellPeriodS = try c.decodeIfPresent(Double.self, forKey: .surfSwellPeriodS)
        surfSwellDirectionDeg = try c.decodeIfPresent(Double.self, forKey: .surfSwellDirectionDeg)
        surfGradeRaw = try c.decodeIfPresent(String.self, forKey: .surfGradeRaw)
    }
}

/// Formate une heure de marée dans le fuseau du port (et non celui de l'appareil).
func formatTideTime(_ date: Date, in timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.timeZone = timeZone
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

enum WidgetSharedKeys {
    static let appGroupId = "group.seb.Tide-It"
    static let dataKey = "tide_it_widget_data"
    static let availablePortsKey = "tide_it_available_ports"
    /// Dernier SPOT DE SURF visité (snapshot complet) → le widget surf reste « collant » sur ton
    /// spot même quand le port actif est un port classique (sinon il tomberait sur l'état vide).
    static let lastSurfDataKey = "tide_it_last_surf_data"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    /// Clé par port pour widget configurable
    static func portDataKey(_ portId: String) -> String {
        "tide_it_port_\(portId)"
    }
}

// MARK: - Shared Unit Formatter (widgets, watch, clip)

enum SharedUnitFormatter {
    private static var shared: UserDefaults? { UserDefaults(suiteName: WidgetSharedKeys.appGroupId) }

    static var isImperial: Bool {
        shared?.string(forKey: "measureSystem") == "imperial"
    }

    static var windUnitLabel: String {
        shared?.string(forKey: "windSpeedUnit") ?? "km/h"
    }

    static func height(_ meters: Double, decimals: Int = 1) -> String {
        if isImperial {
            return String(format: "%.\(decimals)f ft", meters * 3.28084)
        }
        return String(format: "%.\(decimals)f m", meters)
    }

    static func temp(_ celsius: Double) -> String {
        if isImperial {
            return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
        return "\(Int(celsius.rounded()))°C"
    }

    /// Formate une vitesse de vent (stockée en km/h) dans l'unité réglée par l'utilisateur.
    static func windSpeed(_ kmh: Double) -> String {
        let unit = shared?.string(forKey: "windSpeedUnit") ?? "km/h"
        let v: Double
        switch unit {
        case "kn":  v = kmh / 1.852
        case "m/s": v = kmh / 3.6
        case "mph": v = kmh / 1.609344
        default:    v = kmh   // km/h
        }
        return "\(Int(v.rounded())) \(unit)"
    }

    /// Direction cardinale FR (N, NE, E, SE, S, SO, O, NO) depuis un cap en degrés.
    static func windCardinal(_ deg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let idx = Int((deg + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return dirs[max(0, min(idx, 7))]
    }
}

// MARK: - Résolution autonome des marées

/// Trouve la paire (previous, next, second) depuis allTides pour un instant donné
func resolveTides(from allTides: [SimpleTide], at date: Date) -> (previous: SimpleTide, next: SimpleTide, second: SimpleTide?)? {
    guard allTides.count >= 2 else { return nil }

    // Recherche binaire : premier index dont la date est strictement > date
    var lo = 0, hi = allTides.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if allTides[mid].date <= date {
            lo = mid + 1
        } else {
            hi = mid
        }
    }

    guard lo > 0, lo < allTides.count else { return nil }

    let previous = allTides[lo - 1]
    let next = allTides[lo]
    let second = (lo + 1 < allTides.count) ? allTides[lo + 1] : nil

    return (previous, next, second)
}

/// Résout les marées depuis allTides et retourne un WidgetSharedData patché
func resolvedSharedData(from data: WidgetSharedData, at date: Date) -> WidgetSharedData {
    guard !data.allTides.isEmpty,
          let r = resolveTides(from: data.allTides, at: date) else { return data }

    // Interpolation cosinus pour la hauteur courante
    let total = r.next.date.timeIntervalSince(r.previous.date)
    let elapsed = date.timeIntervalSince(r.previous.date)
    let frac = total > 0 ? min(max(elapsed / total, 0), 1) : 0
    let cosP = (1 - cos(frac * .pi)) / 2
    let height = r.previous.height + (r.next.height - r.previous.height) * cosP

    // Coef du CYCLE EN COURS : pleine mer (porteuse du coef) la plus proche de `date`.
    // Se met à jour quand on passe d'un cycle à l'autre (vs « premier coef du jour » figé).
    let todayCoef = data.allTides
        .filter { $0.isHigh && $0.coefficient != nil }
        .min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })?
        .coefficient

    return WidgetSharedData(
        portName: data.portName,
        nextTideDate: r.next.date,
        nextTideHeight: r.next.height,
        nextTideIsHigh: r.next.isHigh,
        nextTideCoef: r.next.coefficient,
        currentHeight: height,
        trend: r.next.isHigh ? "Montante" : "Descendante",
        updatedAt: date,
        todayCoef: todayCoef ?? data.todayCoef,
        previousTideDate: r.previous.date,
        previousTideHeight: r.previous.height,
        secondTideDate: r.second?.date,
        secondTideHeight: r.second?.height,
        secondTideIsHigh: r.second?.isHigh,
        secondTideCoef: r.second?.coefficient,
        allTides: data.allTides,
        timeZoneIdentifier: data.timeZoneIdentifier,
        measureSystemRaw: data.measureSystemRaw,
        windSpeedUnitRaw: data.windSpeedUnitRaw,
        sunrise: data.sunrise,
        sunset: data.sunset,
        observedWindKmh: data.observedWindKmh,
        observedWindGustKmh: data.observedWindGustKmh,
        observedWindDirDeg: data.observedWindDirDeg,
        observedWindStation: data.observedWindStation,
        observedWindDistanceKm: data.observedWindDistanceKm,
        observedWindDate: data.observedWindDate,
        realtimeWindLocked: data.realtimeWindLocked,
        // Vent PRÉVU (Open-Meteo) : sans ça, le widget Vent affichait « Aucune balise à
        // proximité » au lieu de la prévision quand aucune balise réelle n'est dispo.
        forecastWindKmh: data.forecastWindKmh,
        forecastWindGustKmh: data.forecastWindGustKmh,
        forecastWindDirDeg: data.forecastWindDirDeg,
        forecastWindConfidence: data.forecastWindConfidence,
        portId: data.portId,
        latitude: data.latitude,
        longitude: data.longitude,
        // Surf : la houle/le verdict ne se ré-interpolent pas par entrée (la marée si) → on les
        // reporte tels quels, sinon le widget surf retomberait sur « indisponible » à chaque entrée.
        isSurfSpot: data.isSurfSpot,
        surfSwellHeightM: data.surfSwellHeightM,
        surfSwellPeriodS: data.surfSwellPeriodS,
        surfSwellDirectionDeg: data.surfSwellDirectionDeg,
        surfGradeRaw: data.surfGradeRaw
    )
}
