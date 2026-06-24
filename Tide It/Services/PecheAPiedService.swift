//
//  PecheAPiedService.swift
//  Tide It
//
//  Moteur du mode « Pêche à pied ».
//
//  Pour chaque basse mer à venir, calcule :
//    - le coefficient associé (vives-eaux = estran plus découvert),
//    - la fenêtre « estran découvert » autour de la BM (résolution analytique
//      de la courbe cosinus entre PM et BM),
//    - l'heure de RETOUR de l'eau (sécurité),
//    - un score combinant coefficient et luminosité (jour/nuit).
//

import Foundation
import CoreLocation
import UserNotifications
import os.log

@MainActor
final class PecheAPiedService {
    static let shared = PecheAPiedService()
    private init() {}

    struct Config {
        /// Horizon de calcul (jours)
        var horizonDays = 21
        /// Marge au-dessus de la BM en-deçà de laquelle l'estran est « travaillable »
        var exposureMarginMeters = 1.0
        /// En-dessous, l'estran se découvre trop peu pour valoir le déplacement
        var minCoefficient = 55
    }

    // MARK: - API

    /// Génère les sessions de pêche à pied à venir, triées par date.
    func sessions(
        from sortedTides: [TideData],
        now: Date = Date(),
        sunTimes: [(sunrise: Date, sunset: Date)] = [],
        config: Config = Config()
    ) -> [ForagingSession] {
        guard sortedTides.count >= 3 else { return [] }
        let calendar = Calendar.current
        guard let horizon = calendar.date(byAdding: .day, value: config.horizonDays, to: now) else { return [] }

        var sessions: [ForagingSession] = []

        for (index, tide) in sortedTides.enumerated() where !tide.isHighTide {
            guard tide.date >= now, tide.date <= horizon else { continue }

            guard let coef = nearestCoefficient(aroundIndex: index, in: sortedTides),
                  coef >= config.minCoefficient else { continue }

            let precedingHigh = sortedTides[..<index].last(where: { $0.isHighTide })
            let followingHigh = (index + 1 < sortedTides.count)
                ? sortedTides[(index + 1)...].first(where: { $0.isHighTide })
                : nil

            let threshold = tide.height + config.exposureMarginMeters
            let window = exposedWindow(
                low: tide,
                precedingHigh: precedingHigh,
                followingHigh: followingHigh,
                threshold: threshold
            )

            let daylight = daylightStatus(for: tide.date, sunTimes: sunTimes)
            let score = computeScore(coefficient: coef, daylight: daylight)

            sessions.append(ForagingSession(
                lowTideDate: tide.date,
                lowTideHeight: tide.height,
                coefficient: coef,
                windowStart: window.start,
                windowEnd: window.end,
                daylight: daylight,
                score: score
            ))
        }

        return sessions.sorted { $0.lowTideDate < $1.lowTideDate }
    }

    /// Meilleure sortie dans les `days` prochains jours (pour la mise en avant).
    func bestSession(in sessions: [ForagingSession], withinDays days: Int = 10, now: Date = Date()) -> ForagingSession? {
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let candidates = sessions.filter { $0.lowTideDate <= horizon }
        return (candidates.isEmpty ? sessions : candidates)
            .max { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.lowTideDate > rhs.lowTideDate   // à score égal, le plus proche
            }
    }

    // MARK: - Coefficient associé à une BM

    /// Le coefficient est porté par les PM. On prend le max des PM voisines
    /// (elles décrivent le même état vives-eaux / mortes-eaux).
    private func nearestCoefficient(aroundIndex index: Int, in tides: [TideData]) -> Int? {
        var coefs: [Int] = []
        if let prevPM = tides[..<index].last(where: { $0.isHighTide }), let c = prevPM.coefficient {
            coefs.append(c)
        }
        if index + 1 < tides.count,
           let nextPM = tides[(index + 1)...].first(where: { $0.isHighTide }), let c = nextPM.coefficient {
            coefs.append(c)
        }
        return coefs.max()
    }

    // MARK: - Fenêtre « estran découvert » (résolution analytique cosinus)

    /// Hauteur modélisée par interpolation cosinus entre deux extrema (règle des
    /// douzièmes). On résout directement l'instant où la courbe croise `threshold`.
    private func exposedWindow(
        low: TideData,
        precedingHigh: TideData?,
        followingHigh: TideData?,
        threshold: Double
    ) -> (start: Date?, end: Date?) {
        var start: Date?
        var end: Date?

        // Descente PM → BM : premier instant où h ≤ threshold
        if let high = precedingHigh, high.height > low.height {
            let k = clamp01((threshold - high.height) / (low.height - high.height))
            let p = acos(1 - 2 * k) / .pi          // progression normalisée [0,1]
            let dt = low.date.timeIntervalSince(high.date)
            start = high.date.addingTimeInterval(p * dt)
        } else {
            start = low.date.addingTimeInterval(-2 * 3600)   // fallback ~2 h avant
        }

        // Montée BM → PM : dernier instant où h ≤ threshold
        if let high = followingHigh, high.height > low.height {
            let k = clamp01((threshold - low.height) / (high.height - low.height))
            let p = acos(1 - 2 * k) / .pi
            let dt = high.date.timeIntervalSince(low.date)
            end = low.date.addingTimeInterval(p * dt)
        } else {
            end = low.date.addingTimeInterval(2 * 3600)
        }

        return (start, end)
    }

    private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    // MARK: - Luminosité

    private func daylightStatus(for date: Date, sunTimes: [(sunrise: Date, sunset: Date)]) -> DaylightStatus {
        let calendar = Calendar.current
        guard let sun = sunTimes.first(where: { calendar.isDate($0.sunrise, inSameDayAs: date) }) else {
            return .unknown
        }
        let twilight: TimeInterval = 45 * 60
        if date >= sun.sunrise, date <= sun.sunset { return .day }
        if date >= sun.sunrise.addingTimeInterval(-twilight),
           date <= sun.sunset.addingTimeInterval(twilight) { return .twilight }
        return .night
    }

    // MARK: - Score

    /// Score 0-100 : coefficient dominant (78 %) + luminosité (22 %).
    private func computeScore(coefficient: Int, daylight: DaylightStatus) -> Int {
        let coefScore = clamp01((Double(coefficient) - 45) / (110 - 45))
        let dayScore: Double
        switch daylight {
        case .day:      dayScore = 1.0
        case .twilight: dayScore = 0.7
        case .night:    dayScore = 0.45
        case .unknown:  dayScore = 0.85   // au-delà des prévisions soleil : surtout le coef
        }
        return Int(((coefScore * 0.78 + dayScore * 0.22) * 100).rounded())
    }
}

// MARK: - Notifications proactives « Pêche à pied »

/// Programme une alerte avant les prochaines grandes marées (estran bien découvert).
/// Gate : toggle utilisateur + premium.
@MainActor
enum PecheAPiedNotifier {
    private static let scanThrottle: TimeInterval = 3 * 3600   // au plus toutes les 3 h
    private static let minCoefficient = 90                     // n'alerte que sur les vraies grandes marées
    private static let leadTime: TimeInterval = 3 * 3600       // prévenir ~3 h avant l'ouverture de la fenêtre
    private static let minLeadSeconds: TimeInterval = 90 * 60  // pas d'alerte si < 1h30
    private static let horizonDays = 6                         // on n'anticipe pas au-delà de ~1 semaine
    private static let notifID = "peche_a_pied_window"

    private enum Keys {
        static let lastScan = "peche_lastNotifyScan"
        static let scheduledSig = "peche_scheduledSig"
    }

    /// Lance un scan throttlé et programme une notification pour la meilleure grande marée à venir.
    static func maybeScanAndSchedule(tideService: TideService) async {
        guard UserDefaults.standard.object(forKey: "pecheAlertsEnabled") as? Bool ?? false else { return }
        guard PremiumManager.shared.canUsePecheAPied else { return }

        let now = Date()
        if let last = UserDefaults.standard.object(forKey: Keys.lastScan) as? Date,
           now.timeIntervalSince(last) < scanThrottle { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        guard let port = tideService.selectedPort else { return }

        // Couverture sur 3 semaines + lever/coucher (scoring jour/nuit).
        await tideService.fetchExtendedPredictions(days: 21)
        let loc = CLLocation(latitude: port.latitude, longitude: port.longitude)
        let raw = await WeatherService.shared.getSunriseSunsetRange(for: loc, from: now, days: horizonDays)
        let sun: [(sunrise: Date, sunset: Date)] = raw.compactMap {
            guard let sr = $0.sunrise, let ss = $0.sunset else { return nil }
            return (sunrise: sr, sunset: ss)
        }

        let tides = tideService.allTideData.isEmpty ? tideService.tideData : tideService.allTideData
        let sessions = PecheAPiedService.shared.sessions(from: tides, sunTimes: sun)
        UserDefaults.standard.set(now, forKey: Keys.lastScan)

        let cal = Calendar.inTimeZone(port.portTimeZone)
        let horizon = cal.date(byAdding: .day, value: horizonDays, to: now) ?? now
        guard let top = sessions.first(where: { s in
            s.coefficient >= minCoefficient
            && (s.windowStart ?? s.lowTideDate) <= horizon
            && (s.windowStart ?? s.lowTideDate).timeIntervalSince(now) > minLeadSeconds
        }) else { return }

        let windowOpen = top.windowStart ?? top.lowTideDate
        let dayKey = Int(cal.startOfDay(for: top.lowTideDate).timeIntervalSince1970 / 86400)
        let signature = "\(port.id)|\(dayKey)|\(top.coefficient)"
        guard UserDefaults.standard.string(forKey: Keys.scheduledSig) != signature else { return }

        schedule(session: top, windowOpen: windowOpen, port: port, signature: signature, now: now)
    }

    private static func schedule(session: ForagingSession, windowOpen: Date, port: Port, signature: String, now: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notifID])

        let fireDate = max(now.addingTimeInterval(60), windowOpen.addingTimeInterval(-leadTime))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let timeFmt = CachedDateFormatter.make("HH:mm", timeZone: port.portTimeZone)
        let time = timeFmt.string(from: windowOpen)

        let content = UNMutableNotificationContent()
        content.title = "Grande marée à \(port.name)"
        content.body = "Coefficient \(session.coefficient) \(whenWord(session.lowTideDate, port: port)) — estran découvert dès \(time)."
        content.sound = .default
        content.userInfo = ["portId": port.id, "kind": "pecheAPied"]

        center.add(UNNotificationRequest(identifier: notifID, content: content, trigger: trigger))
        UserDefaults.standard.set(signature, forKey: Keys.scheduledSig)
        appLogger.info("[PecheAPied] Alerte programmée: coef \(session.coefficient) @ \(port.name)")
    }

    private static func whenWord(_ date: Date, port: Port) -> String {
        let cal = Calendar.inTimeZone(port.portTimeZone)
        if cal.isDateInToday(date) { return "aujourd'hui" }
        if cal.isDateInTomorrow(date) { return "demain" }
        return "le " + CachedDateFormatter.make("EEEE", timeZone: port.portTimeZone).string(from: date)
    }
}
