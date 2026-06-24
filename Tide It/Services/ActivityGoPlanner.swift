//
//  ActivityGoPlanner.swift
//  Tide It
//
//  Moteur du calendrier 7 jours : pour chaque SPORT ACTIVÉ, calcule ses fenêtres GO sur la
//  semaine à partir de SES conditions (« Mes sports »).
//
//  Une fenêtre GO = heures consécutives, de jour, où TOUTES les conditions du sport sont vraies.
//  On réutilise la logique live `AlertCondition.isSatisfied` (vent synthétique « frais » construit
//  depuis la prévision horaire, exactement comme `AlertForecaster`) → mêmes unités, même
//  comparateur : ce que montre le calendrier = ce que déclencheraient les mêmes conditions.
//

import Foundation

/// Fenêtres GO d'un sport sur une journée (une lane dans le calendrier).
struct SportLane: Identifiable {
    var id: WindSport { sport }
    let sport: WindSport
    let windows: [GoWindow]
}

/// Plan d'une journée : les lanes (par sport) qui ont au moins une fenêtre GO ce jour-là.
struct DaySportPlan: Identifiable {
    var id: Date { day }        // identité STABLE entre recalculs
    let day: Date               // début de journée (tz du port)
    let lanes: [SportLane]

    var isEmpty: Bool { lanes.allSatisfy { $0.windows.isEmpty } }
}

/// Donne la note 0–100 d'un sport pour une heure de prévision (mode AUTO). Injecté par
/// l'appelant @MainActor (qui détient ActivityScoreService) → le planner reste découplé du scoring.
typealias GoHourScorer = (WindSport, HourlyForecast, RiderLevel) -> Int

enum ActivityGoPlanner {

    /// Fenêtres GO d'un sport sur l'ensemble des prévisions. Trois critères selon le sport :
    ///  - AUTO (exclusif) : note de l'app ≥ seuil du NIVEAU rider (via `scorer`, calé sur le niveau) ;
    ///  - SURF : `SurfConditions` (houle + période + sens + vent + marée), resserré au niveau rider ;
    ///  - manuel : toutes les conditions de vent vraies.
    static func windows(for setup: SportSetup,
                        forecasts: [HourlyForecast],
                        sunTimes: [(sunrise: Date, sunset: Date)],
                        tideData: [TideData],
                        scorer: GoHourScorer? = nil) -> [GoWindow] {
        let sorted = forecasts.sorted { $0.time < $1.time }

        // Mode AUTO (exclusif) : « l'app calcule » → GO quand sa note ≥ seuil. Si aucun scorer
        // n'est fourni (ex. contexte sans ActivityScoreService), on retombe sur les critères ci-dessous.
        if setup.auto, let scorer {
            let threshold = setup.riderLevel.goThreshold
            return buildWindows(sorted, sunTimes: sunTimes) { scorer(setup.sport, $0, setup.riderLevel) >= threshold }
        }

        // SURF (sport de HOULE) : chemin dédié SurfConditions, resserré au CONFORT du niveau rider.
        if setup.sport.isSurf {
            let surf = (setup.surfConditions ?? SurfConditions()).adjusted(for: setup.riderLevel)
            let needsTide = surf.idealTideStage != nil && !tideData.isEmpty
            return buildWindows(sorted, sunTimes: sunTimes) { f in
                let state = needsTide ? TideCalculator.currentState(at: f.time, sortedTides: tideData) : nil
                return surf.isSatisfied(at: f, tideState: state)
            }
        }

        // Manuel (vent). « Le vent s'établit » est stateful (jamais vrai en projection) → ignoré ici.
        let active = setup.conditions.filter { $0.type != .windEstablishing }
        guard !active.isEmpty else { return [] }   // sans condition exploitable → pas de GO
        return buildWindows(sorted, sunTimes: sunTimes) { f in
            allSatisfied(active, at: f, tideData: tideData, sunTimes: sunTimes)
        }
    }

    /// Constructeur commun de fenêtres : runs d'heures de JOUR consécutives où `isGo` est vrai,
    /// brefs creux (≤ 1 h) comblés, durée mini 1 h. Factorise les 3 critères (auto/surf/manuel).
    private static func buildWindows(_ sorted: [HourlyForecast],
                                     sunTimes: [(sunrise: Date, sunset: Date)],
                                     isGo: (HourlyForecast) -> Bool) -> [GoWindow] {
        var windows: [GoWindow] = []
        var runStart: Date?
        var lastOK: Date?
        for f in sorted {
            let ok = WindTidePlanner.isDaylight(f.time, sunTimes: sunTimes) && isGo(f)
            if ok {
                if runStart == nil { runStart = f.time }
                lastOK = f.time
            } else if let s = runStart, let e = lastOK {
                windows.append(GoWindow(start: s, end: e.addingTimeInterval(3600)))
                runStart = nil; lastOK = nil
            }
        }
        if let s = runStart, let e = lastOK {
            windows.append(GoWindow(start: s, end: e.addingTimeInterval(3600)))
        }
        return WindTidePlanner.bridgeBriefGaps(windows).filter { $0.end.timeIntervalSince($0.start) >= 3600 }
    }

    private static func allSatisfied(_ conditions: [AlertCondition], at f: HourlyForecast,
                                     tideData: [TideData], sunTimes: [(sunrise: Date, sunset: Date)]) -> Bool {
        // Mesure « observée » synthétique (toujours fraîche) → utilisée par la logique vent.
        let synth = WindReading(date: Date(), speedAvgKmh: f.windSpeedKmh, gustKmh: f.windGustKmh,
                                minKmh: nil, directionDegrees: f.windDirection)
        let (sr, ss) = sunForDay(sunTimes, f.time)
        return conditions.allSatisfy {
            $0.isSatisfied(tideData: tideData, weatherData: nil, currentTime: f.time,
                           sunriseTime: sr, sunsetTime: ss, observedWind: synth)
        }
    }

    /// Plan jour par jour pour les sports demandés (déjà filtrés « activés » par l'appelant).
    static func plan(setups: [SportSetup],
                     forecasts: [HourlyForecast],
                     sunTimes: [(sunrise: Date, sunset: Date)],
                     tideData: [TideData],
                     from start: Date, days: Int, calendar: Calendar,
                     scorer: GoHourScorer? = nil) -> [DaySportPlan] {
        let perSport: [(WindSport, [GoWindow])] = setups.map {
            ($0.sport, windows(for: $0, forecasts: forecasts, sunTimes: sunTimes, tideData: tideData, scorer: scorer))
        }
        let startDay = calendar.startOfDay(for: start)
        return (0..<max(1, days)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let lanes: [SportLane] = perSport.compactMap { (sport, wins) in
                let dayWins = wins
                    .filter { $0.start < dayEnd && $0.end > day }
                    .map { GoWindow(start: max($0.start, day), end: min($0.end, dayEnd)) }
                return dayWins.isEmpty ? nil : SportLane(sport: sport, windows: dayWins)
            }
            return DaySportPlan(day: day, lanes: lanes)
        }
    }

    private static func sunForDay(_ sun: [(sunrise: Date, sunset: Date)], _ t: Date) -> (Date?, Date?) {
        // tz-AGNOSTIQUE : on prend le couple dont le « midi solaire » (≈ milieu de la journée) est le
        // plus proche de t. Avant, `Calendar.current.isDate(inSameDayAs:)` utilisait le fuseau du
        // DEVICE → mauvais couple (voire aucun) pour un port lointain, donc condition soleil cassée.
        let match = sun.min(by: {
            let m0 = $0.sunrise.addingTimeInterval($0.sunset.timeIntervalSince($0.sunrise) / 2)
            let m1 = $1.sunrise.addingTimeInterval($1.sunset.timeIntervalSince($1.sunrise) / 2)
            return abs(m0.timeIntervalSince(t)) < abs(m1.timeIntervalSince(t))
        })
        return (match?.sunrise, match?.sunset)
    }
}
