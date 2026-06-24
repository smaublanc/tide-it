//
//  WidgetSharedTypes.swift
//  Tide Watch Watch App
//
//  Shared types duplicated from the iOS target so the Watch app
//  can read widget data without depending on TideItWidget.
//

import Foundation

/// Point de maree leger pour resolution autonome widget/watch
struct SimpleTide: Codable, Equatable, Sendable {
    let date: Date
    let height: Double
    let isHigh: Bool
    let coefficient: Int?
}

/// Donnees affichees dans le widget - encodees par l'app, lues par le widget
struct WidgetSharedData: Codable, Sendable {
    let portName: String
    let nextTideDate: Date
    let nextTideHeight: Double
    let nextTideIsHigh: Bool
    let nextTideCoef: Int?
    let currentHeight: Double
    let trend: String
    let updatedAt: Date

    // Coefficient du jour (toujours rempli si disponible, independant de la maree)
    let todayCoef: Int?

    // Maree precedente (pour interpolation cote widget)
    let previousTideDate: Date?
    let previousTideHeight: Double?

    // 2eme maree (celle apres la prochaine)
    let secondTideDate: Date?
    let secondTideHeight: Double?
    let secondTideIsHigh: Bool?
    let secondTideCoef: Int?

    // Tableau complet des marees (7 jours) pour resolution autonome
    let allTides: [SimpleTide]

    // Fuseau horaire du port -> la watch affiche les heures en LOCAL du port
    let timeZoneIdentifier: String?

    let measureSystemRaw: String?
    let windSpeedUnitRaw: String?
    let sunrise: Date?
    let sunset: Date?

    // Vent observe temps reel (balise la plus proche). Optionnels.
    let observedWindKmh: Double?
    let observedWindGustKmh: Double?
    let observedWindDirDeg: Double?
    let observedWindStation: String?
    let observedWindDistanceKm: Double?
    let observedWindDate: Date?
    // Position du port + verrou premium (envoyés par le tel) → autorisent le fetch vent DIRECT
    // depuis la Watch (sans tel). `var` + défaut → init memberwise inchangé.
    var latitude: Double? = nil
    var longitude: Double? = nil
    var realtimeWindLocked: Bool? = nil

    /// Fuseau du port (replie sur le fuseau de l'appareil si absent).
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
         observedWindDate: Date? = nil) {
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

    // Decodage retrocompatible : allTides peut etre absent dans les anciennes donnees
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
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        realtimeWindLocked = try c.decodeIfPresent(Bool.self, forKey: .realtimeWindLocked)
    }
}

/// Formate une heure de maree dans le fuseau du port (et non celui de l'appareil).
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

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }
}

// MARK: - Shared Unit Formatter (watch)

enum SharedUnitFormatter {
    private static var shared: UserDefaults? { UserDefaults(suiteName: WidgetSharedKeys.appGroupId) }

    static var isImperial: Bool {
        shared?.string(forKey: "measureSystem") == "imperial"
    }

    static func height(_ meters: Double, decimals: Int = 1) -> String {
        if isImperial {
            return String(format: "%.\(decimals)f ft", meters * 3.28084)
        }
        return String(format: "%.\(decimals)f m", meters)
    }

    /// Vitesse de vent (stockee en km/h) dans l'unite reglee (primee depuis l'iPhone).
    static func windSpeed(_ kmh: Double) -> String {
        let unit = shared?.string(forKey: "windSpeedUnit") ?? "km/h"
        let v: Double
        switch unit {
        case "kn":  v = kmh / 1.852
        case "m/s": v = kmh / 3.6
        case "mph": v = kmh / 1.609344
        default:    v = kmh
        }
        return "\(Int(v.rounded())) \(unit)"
    }

    /// Direction cardinale FR depuis un cap en degres.
    static func windCardinal(_ deg: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let idx = Int((deg + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return dirs[max(0, min(idx, 7))]
    }
}

// MARK: - Resolution autonome des marees

/// Trouve la paire (previous, next, second) depuis allTides pour un instant donne
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

/// Resout les marees depuis allTides et retourne un WidgetSharedData patche
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
        observedWindDate: data.observedWindDate
    )
}
