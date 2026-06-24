//
//  AlertForecaster.swift
//  Tide It
//
//  Projette une alerte sur les jours à venir pour répondre à deux questions de l'UI moderne :
//    • « prochaine fois » — quand l'alerte se déclencherait-elle ensuite ?
//    • « dry-run » — combien de fois sonnerait-elle sur la fenêtre ?
//
//  Réutilise EXACTEMENT la logique live (`AlertCondition.isSatisfied`) : marée/coef/temps/soleil
//  sur les prédictions, et vent réinjecté comme une mesure « observée » fraîche issue de la
//  prévision horaire (mêmes unités, même comparateur → l'aperçu ne ment pas).
//

import Foundation

enum AlertForecaster {

    struct Result {
        let next: Date?       // prochain déclenchement (nil = aucun sur la fenêtre)
        let count: Int        // nombre de déclenchements (fronts montants, espacés du cooldown)
        let projectable: Bool // false si une condition n'est pas projetable (windEstablishing)
    }

    static func forecast(conditions: [AlertCondition],
                         requireAll: Bool,
                         tideData: [TideData],
                         windForecasts: [HourlyForecast],
                         sunTimes: [(sunrise: Date, sunset: Date)],
                         from: Date = Date(),
                         days: Int = 7,
                         cooldown: TimeInterval = 3600) -> Result {
        guard !conditions.isEmpty, !tideData.isEmpty else {
            return Result(next: nil, count: 0, projectable: true)
        }
        // « Le vent s'établit » est STATEFUL (confirmation) → non projetable.
        if conditions.contains(where: { $0.type == .windEstablishing }) {
            return Result(next: nil, count: 0, projectable: false)
        }

        let step: TimeInterval = 1800   // pas de 30 min
        let end = from.addingTimeInterval(Double(days) * 86400)
        let wind = windForecasts.sorted { $0.time < $1.time }

        var next: Date?
        var count = 0
        var lastTrigger: Date?
        var prevSatisfied = false

        var t = from
        while t <= end {
            let sat = satisfied(conditions, requireAll: requireAll,
                                tide: tideData, wind: wind, sun: sunTimes, at: t)
            if sat && !prevSatisfied,
               lastTrigger == nil || t.timeIntervalSince(lastTrigger!) >= cooldown {
                count += 1
                if next == nil { next = t }
                lastTrigger = t
            }
            prevSatisfied = sat
            t.addTimeInterval(step)
        }
        return Result(next: next, count: count, projectable: true)
    }

    // MARK: - Privé

    private static func satisfied(_ conditions: [AlertCondition], requireAll: Bool,
                                  tide: [TideData], wind: [HourlyForecast],
                                  sun: [(sunrise: Date, sunset: Date)], at t: Date) -> Bool {
        // Mesure « observée » synthétique issue de la prévision (toujours « fraîche » → utilisée
        // par la logique live des conditions vent).
        let synthWind: WindReading? = nearestWind(wind, t).map {
            WindReading(date: Date(), speedAvgKmh: $0.windSpeedKmh, gustKmh: $0.windGustKmh,
                        minKmh: nil, directionDegrees: $0.windDirection)
        }
        let (sr, ss) = sunForDay(sun, t)
        let results = conditions.map {
            $0.isSatisfied(tideData: tide, weatherData: nil, currentTime: t,
                           sunriseTime: sr, sunsetTime: ss, observedWind: synthWind)
        }
        return requireAll ? results.allSatisfy { $0 } : results.contains { $0 }
    }

    private static func nearestWind(_ wind: [HourlyForecast], _ t: Date) -> HourlyForecast? {
        wind.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }
    }

    private static func sunForDay(_ sun: [(sunrise: Date, sunset: Date)], _ t: Date) -> (Date?, Date?) {
        // tz-AGNOSTIQUE (cf. ActivityGoPlanner) : couple dont le « midi solaire » est le plus proche
        // de t, au lieu de `Calendar.current.isDate(inSameDayAs:)` qui cassait pour les ports lointains.
        let match = sun.min(by: {
            let m0 = $0.sunrise.addingTimeInterval($0.sunset.timeIntervalSince($0.sunrise) / 2)
            let m1 = $1.sunrise.addingTimeInterval($1.sunset.timeIntervalSince($1.sunrise) / 2)
            return abs(m0.timeIntervalSince(t)) < abs(m1.timeIntervalSince(t))
        })
        return (match?.sunrise, match?.sunset)
    }
}
