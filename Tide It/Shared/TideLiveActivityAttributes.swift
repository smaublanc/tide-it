//
//  TideLiveActivityAttributes.swift
//  Tide It
//
//  Modèle partagé pour les Live Activities (Dynamic Island + Lock Screen)
//

import ActivityKit
import Foundation

struct TideLiveActivityAttributes: ActivityAttributes {
    /// Données statiques (ne changent pas pendant la Live Activity)
    let portName: String

    /// Point d'extrémum de marée (PM/BM) pour dessiner la courbe signature.
    struct CurvePoint: Codable, Hashable {
        let t: Date       // instant de l'extrémum
        let h: Double     // hauteur (m)
        let high: Bool    // true = pleine mer
    }

    /// Données dynamiques mises à jour en temps réel
    struct ContentState: Codable, Hashable {
        let currentHeight: Double
        let trend: String           // "Montante" / "Descendante" (ou rising/falling/…)
        let nextTideDate: Date
        let nextTideHeight: Double
        let nextTideIsHigh: Bool
        let nextTideCoef: Int?
        let tideProgress: Double    // 0...1
        /// Extrema autour de « maintenant » → tracé de la courbe signature.
        let curve: [CurvePoint]
        /// Vent (km/h) le plus proche : observé si dispo, sinon prévu. Pour la DA mode vent.
        let windKmh: Double?
        let windGustKmh: Double?
        let windDirDeg: Double?
        /// `true` si `windKmh` vient d'une balise réelle (sinon prévu).
        let windIsLive: Bool?
        /// Vent horaire autour de « maintenant » (km/h) → mini-courbe vent néon.
        let windCurve: [Double]
        /// Sport actuellement GO (nom) si une fenêtre est ouverte maintenant, sinon nil.
        let goSport: String?
        /// Lever / coucher du soleil du jour → arc solaire sous la courbe de marée.
        let sunrise: Date?
        let sunset: Date?

        init(currentHeight: Double,
             trend: String,
             nextTideDate: Date,
             nextTideHeight: Double,
             nextTideIsHigh: Bool,
             nextTideCoef: Int?,
             tideProgress: Double,
             curve: [CurvePoint] = [],
             windKmh: Double? = nil,
             windGustKmh: Double? = nil,
             windDirDeg: Double? = nil,
             windIsLive: Bool? = nil,
             windCurve: [Double] = [],
             goSport: String? = nil,
             sunrise: Date? = nil,
             sunset: Date? = nil) {
            self.currentHeight = currentHeight
            self.trend = trend
            self.nextTideDate = nextTideDate
            self.nextTideHeight = nextTideHeight
            self.nextTideIsHigh = nextTideIsHigh
            self.nextTideCoef = nextTideCoef
            self.tideProgress = tideProgress
            self.curve = curve
            self.windKmh = windKmh
            self.windGustKmh = windGustKmh
            self.windDirDeg = windDirDeg
            self.windIsLive = windIsLive
            self.windCurve = windCurve
            self.goSport = goSport
            self.sunrise = sunrise
            self.sunset = sunset
        }

        // Décodage rétro-compatible : une activité encodée AVANT l'ajout de `curve`
        // (mise à jour de l'app) reste décodable → pas de Live Activity cassée.
        enum CodingKeys: String, CodingKey {
            case currentHeight, trend, nextTideDate, nextTideHeight, nextTideIsHigh, nextTideCoef, tideProgress, curve
            case windKmh, windGustKmh, windDirDeg, windIsLive, windCurve, goSport, sunrise, sunset
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currentHeight = try c.decode(Double.self, forKey: .currentHeight)
            trend = try c.decode(String.self, forKey: .trend)
            nextTideDate = try c.decode(Date.self, forKey: .nextTideDate)
            nextTideHeight = try c.decode(Double.self, forKey: .nextTideHeight)
            nextTideIsHigh = try c.decode(Bool.self, forKey: .nextTideIsHigh)
            nextTideCoef = try c.decodeIfPresent(Int.self, forKey: .nextTideCoef)
            tideProgress = try c.decode(Double.self, forKey: .tideProgress)
            curve = (try? c.decodeIfPresent([CurvePoint].self, forKey: .curve)) ?? []
            windKmh = try? c.decodeIfPresent(Double.self, forKey: .windKmh)
            windGustKmh = try? c.decodeIfPresent(Double.self, forKey: .windGustKmh)
            windDirDeg = try? c.decodeIfPresent(Double.self, forKey: .windDirDeg)
            windIsLive = try? c.decodeIfPresent(Bool.self, forKey: .windIsLive)
            windCurve = (try? c.decodeIfPresent([Double].self, forKey: .windCurve)) ?? []
            goSport = try? c.decodeIfPresent(String.self, forKey: .goSport)
            sunrise = try? c.decodeIfPresent(Date.self, forKey: .sunrise)
            sunset = try? c.decodeIfPresent(Date.self, forKey: .sunset)
        }
    }
}
