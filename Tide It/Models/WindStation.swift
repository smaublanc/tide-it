//
//  WindStation.swift
//  Tide It
//
//  Modèles pour les stations d'anémomètres temps réel.
//  MVP : Pioupiou (France, réseau communautaire ~60+ stations côtières).
//  À terme : Holfuy, Météo-France SYNOP.
//

import Foundation
import CoreLocation

struct WindStation: Identifiable, Hashable {
    let id: String
    let name: String
    let source: Source
    let latitude: Double
    let longitude: Double
    let reading: WindReading?
    /// Relevé de HOULE réel (bouées NDBC uniquement). nil pour les balises vent pures.
    /// Affichage/affinage de la note surf — voir WindStationAggregator.nearestWaveReading.
    var wave: WaveReading? = nil

    enum Source: String, Codable {
        case pioupiou
        case holfuy
        case metar          // Aviation weather METAR (NOAA public API)
        case meteoFrance
        case weameter       // Stations WeeWX Weameter (balises côtières FR)
        case ndbc           // Bouées marines NOAA NDBC (couverture mondiale)
        case windsMobi      // Agrégat Winds.mobi (Holfuy/FFVL/Romma/MeteoSwiss… ≤20km, côtier)

        var displayName: String {
            switch self {
            case .pioupiou: return "Pioupiou"
            case .holfuy: return "Holfuy"
            case .metar: return "METAR"
            case .meteoFrance: return "Météo-France"
            case .weameter: return "Weameter"
            case .ndbc: return "Bouée NDBC"
            case .windsMobi: return "Winds.mobi"
            }
        }

        /// Crédit obligatoire selon la licence de la source
        var attributionLabel: String {
            switch self {
            case .pioupiou: return "Données : Pioupiou · CC-BY"
            case .holfuy: return "Données : Holfuy"
            case .metar: return "Données : METAR · NOAA"
            case .meteoFrance: return "Données : Météo-France"
            case .weameter: return "Données : Weameter"
            case .ndbc: return "Données : NDBC · NOAA"
            case .windsMobi: return "Données : winds.mobi"
            }
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Distance en mètres vers une autre position — haversine ZÉRO-ALLOCATION (sur les Double stockés).
    /// L'ancienne version allouait 2 CLLocation par appel ; or le dédoublonnage O(n²) de
    /// WindStationAggregator et chaque `nearest*` (Live Activity, widget, alertes, vent observé)
    /// l'appellent des milliers de fois → churn de tas évité.
    func distance(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
        let r = 6_371_000.0
        let dLat = (coord.latitude - latitude) * .pi / 180
        let dLon = (coord.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(coord.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Relevé de HOULE réel d'une bouée (NDBC). `heightM` = hauteur significative TOTALE (Hs), PAS une
/// partition de houle → ne JAMAIS l'utiliser pour fabriquer la pureté (houle/clapot). Frais < 60 min
/// (les bouées publient ~1×/h). Affichage + affinage de la note surf le jour J.
struct WaveReading: Hashable {
    let date: Date
    let heightM: Double                   // WVHT — hauteur significative totale (m)
    var periodS: Double? = nil            // DPD — période dominante (s)
    var directionDegrees: Double? = nil   // MWD — direction d'où vient la houle (deg)

    var isFresh: Bool { Date().timeIntervalSince(date) < 3600 }
    var ageMinutes: Int { max(0, Int(Date().timeIntervalSince(date) / 60)) }
    /// Âge depuis une horloge FOURNIE (pour synchroniser l'affinage sur le temps courant de la courbe,
    /// pas l'heure murale) — utilisé par la rampe prévision→réel. (Nom distinct de la propriété
    /// `ageMinutes` : un même nom propriété+méthode entre en collision côté appel.)
    func minutesOld(asOf clock: Date) -> Int { max(0, Int(clock.timeIntervalSince(date) / 60)) }
    var ageLabel: String {
        let mins = ageMinutes
        if mins < 1 { return "à l'instant" }
        if mins < 60 { return "il y a \(mins) min" }
        return "il y a \(mins / 60)h\(String(format: "%02d", mins % 60))"
    }
}

struct WindReading: Hashable {
    /// Date de la mesure (UTC)
    let date: Date

    /// Vitesse moyenne (km/h)
    let speedAvgKmh: Double

    /// Rafale maximum sur la période (km/h)
    let gustKmh: Double?

    /// Vitesse minimum (km/h)
    let minKmh: Double?

    /// Direction d'où vient le vent, en degrés (0 = Nord, 90 = Est, ...)
    let directionDegrees: Double

    // Mesures additionnelles (certaines balises type WeeWX/Weameter les fournissent ;
    // nil pour Pioupiou/METAR qui ne donnent que le vent).
    var temperatureC: Double? = nil
    var humidityPct: Double? = nil
    var dewpointC: Double? = nil
    var pressureHpa: Double? = nil
    var pressureTrendHpa: Double? = nil

    /// True si la balise fournit au moins une mesure météo en plus du vent.
    var hasExtraMetrics: Bool {
        temperatureC != nil || humidityPct != nil || dewpointC != nil || pressureHpa != nil
    }

    /// Considérée fraîche si < 60 min. Beaucoup de réseaux (METAR aéroports, bouées
    /// NDBC) ne publient qu'une mesure horaire ; un seuil à 30 min en excluait la
    /// moitié. 60 min reste pertinent pour du vent observé (l'âge réel est affiché).
    var isFresh: Bool {
        Date().timeIntervalSince(date) < 3600
    }

    /// Age en minutes
    var ageMinutes: Int {
        max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    /// Âge depuis une horloge FOURNIE (synchronise la rampe prévision→réel sur le temps courant
    /// de la courbe, pas l'heure murale). Nom distinct de `ageMinutes` (collision propriété+méthode).
    func minutesOld(asOf clock: Date) -> Int { max(0, Int(clock.timeIntervalSince(date) / 60)) }

    /// Libellé d'âge : "à l'instant", "il y a 3 min", "il y a 1h12"
    var ageLabel: String {
        let mins = ageMinutes
        if mins < 1 { return "à l'instant" }
        if mins < 60 { return "il y a \(mins) min" }
        let hours = mins / 60
        let remMin = mins % 60
        return "il y a \(hours)h\(String(format: "%02d", remMin))"
    }

    /// Direction cardinale (N, NE, E, SE, S, SO, O, NO)
    var directionCardinal: String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let idx = Int((directionDegrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return dirs[max(0, min(idx, 7))]
    }
}
