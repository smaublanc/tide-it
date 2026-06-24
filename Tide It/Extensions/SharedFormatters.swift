//
//  SharedFormatters.swift
//  Tide It
//
//  DateFormatters partagés pour éviter leur recréation coûteuse dans les Views.
//  Un DateFormatter est lourd à instancier (parsing locale, calendar) : le
//  réutiliser réduit mémoire et CPU, surtout sur les écrans qui redessinent
//  fréquemment (CalendarView, TodayView).
//
//  Usage :
//      SharedFormatters.time.string(from: date)
//      SharedFormatters.frenchFullDate.string(from: date)
//
//  Pour un fuseau horaire précis, utilisez `.copy(timeZone:)` qui renvoie
//  un formatter distinct — ne JAMAIS muter les instances partagées.
//

import Foundation

enum SharedFormatters {

    /// `HH:mm` — heure système (24h)
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// `EEEE d MMMM` en français (ex. "vendredi 18 avril")
    static let frenchFullDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    /// `EEE d` en français (ex. "ven. 18")
    static let frenchShortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE d"
        return f
    }()

    /// `EEE` en français (ex. "ven.") — jour de la semaine seul
    static let frenchWeekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE"
        return f
    }()

    /// `d MMM` en français (ex. "18 avr.")
    static let frenchMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d MMM"
        return f
    }()

    /// `MMMM` en français (ex. "mai") — nom du mois
    static let frenchMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMMM"
        return f
    }()

    /// `yyyyMMdd` — clé de jour stable, tri/hachage sûrs
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

/// Cache de `DateFormatter` réutilisables. Créer un `DateFormatter` est coûteux
/// (chargement locale/calendrier) : dans une liste, le recréer à chaque ligne/rendu
/// gaspille du CPU. On en conserve donc un par combinaison format + fuseau + locale.
/// Réservé au main actor (rendu UI) — les formatters ne sont jamais mutés après création.
@MainActor
enum CachedDateFormatter {
    private static var cache: [String: DateFormatter] = [:]

    static func make(_ format: String,
                     timeZone: TimeZone,
                     locale: Locale = .current) -> DateFormatter {
        let key = "\(format)\u{1}\(timeZone.identifier)\u{1}\(locale.identifier)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = format
        cache[key] = f
        return f
    }
}

extension Calendar {
    /// Calendrier système réglé sur un fuseau précis. À utiliser pour TOUTE opération
    /// « jour / heure » liée à un port (startOfDay, isDate inSameDay, component(.hour))
    /// afin que les regroupements et les libellés soient cohérents avec l'heure locale
    /// du port — et non celle de l'appareil.
    static func inTimeZone(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar.current
        c.timeZone = timeZone
        return c
    }
}

extension DateFormatter {
    /// Renvoie une COPIE du formatter avec un nouveau fuseau, sans muter l'original.
    /// À utiliser quand on a besoin d'un formatter partagé mais dans un TimeZone spécifique.
    func copy(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = self.dateFormat
        f.locale = self.locale
        f.calendar = self.calendar
        f.timeZone = timeZone
        return f
    }
}
