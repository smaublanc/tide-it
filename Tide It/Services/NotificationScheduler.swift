//
//  NotificationScheduler.swift
//  Tide It
//
//  Pré-programme les notifications pour les alertes de marée
//  même quand l'app est fermée (via UNNotificationRequest)
//

import Foundation
import UserNotifications
import CoreLocation
import os.log

enum NotificationScheduler {

    /// Identifiant prefix pour retrouver nos notifications programmées
    private static let prefix = "tideit.alert."

    // MARK: - Public API

    /// Annule toutes les notifications PROGRAMMÉES (marée + forecast) liées à des alertes
    /// supprimées — utilisé à la suppression d'un port pour ne pas laisser de notif orpheline.
    /// Les identifiants encapsulent l'UUID de l'alerte (`tideit.alert.<id>.<stamp>` et
    /// `tideit.alert.forecast.forecast_<id>_<offset>`) → on filtre par sous-chaîne.
    static func cancelPending(forAlertIds alertIds: [String]) {
        guard !alertIds.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { id in
                alertIds.contains { id.contains($0) }
            }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    /// Recalcule et programme toutes les notifications futures pour les alertes actives.
    /// Appelé après fetch de données, modification d'alertes, ou background refresh.
    static func reschedule(alerts: [TideAlert], tideData: [TideData], portId: String?,
                           portLocation: CLLocation? = nil) async {
        // Notifications = 100 % premium. Le gratuit peut CRÉER des alertes (sauvegardées),
        // mais aucune n'est programmée tant qu'il n'est pas abonné. Échoue FERMÉ.
        guard await PremiumManager.shared.isPremium else {
            appLogger.info("NotificationScheduler: notifications réservées au premium, skip")
            return
        }

        let center = UNUserNotificationCenter.current()

        // Vérifier les autorisations
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            appLogger.info("NotificationScheduler: notifications non autorisées, skip")
            return
        }

        // Supprimer toutes les anciennes notifications programmées par nous
        let pending = await center.pendingNotificationRequests()
        let ourIds = pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        if !ourIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ourIds)
            appLogger.debug("NotificationScheduler: \(ourIds.count) anciennes notifications supprimées")
        }

        // Pré-charger sunrise/sunset pour les 7 prochains jours si nécessaire
        let hasSunCondition = alerts.contains { alert in
            alert.conditions.contains { $0.type == .sunriseSunset }
        }
        var sunTimes: [(sunrise: Date?, sunset: Date?)] = []
        if hasSunCondition, let location = portLocation {
            sunTimes = await WeatherService.shared.getSunriseSunsetRange(
                for: location,
                from: Date(),
                days: 7
            )
        }

        // Programmer les nouvelles
        let now = Date()
        var scheduledCount = 0

        for alert in alerts {
            guard alert.isEnabled else { continue }

            // Filtrer par port
            if let alertPort = alert.port, let currentPort = portId, alertPort != currentPort {
                continue
            }

            // L'alerte doit avoir une action notification
            guard let notifAction = alert.actions.first(where: { $0.type == .notification }) else {
                continue
            }

            // Ignorer si conditions contiennent du vent (non prédictible)
            let hasWindCondition = alert.conditions.contains {
                $0.type == .windSpeed || $0.type == .windDirection
            }
            if hasWindCondition { continue }

            // Trouver les prochaines dates déclenchantes (max 8 = ~2 jours)
            let triggerDates = computeTriggerDates(
                alert: alert,
                tideData: tideData,
                sunTimes: sunTimes,
                now: now,
                maxResults: 8
            )

            for date in triggerDates {
                // Respecter le cooldown par rapport au lastTriggered
                if let last = alert.lastTriggered, date.timeIntervalSince(last) < alert.cooldownPeriod {
                    continue
                }

                let content = UNMutableNotificationContent()
                content.title = alert.name
                content.body = notifAction.message ?? "Condition de marée atteinte"
                content.sound = .default
                content.categoryIdentifier = "TIDE_ALERT"

                let interval = date.timeIntervalSince(now)
                guard interval > 10 else { continue } // Pas dans le passé

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: interval,
                    repeats: false
                )

                // Identifiant unique : alert.id + timestamp arrondi à la minute
                let minuteStamp = Int(date.timeIntervalSince1970 / 60)
                let requestId = "\(prefix)\(alert.id.uuidString).\(minuteStamp)"

                let request = UNNotificationRequest(
                    identifier: requestId,
                    content: content,
                    trigger: trigger
                )

                do {
                    try await center.add(request)
                    scheduledCount += 1
                } catch {
                    appLogger.error("NotificationScheduler: erreur ajout \(requestId): \(error.localizedDescription)")
                }
            }
        }

        appLogger.info("NotificationScheduler: \(scheduledCount) notifications programmées")
    }

    // MARK: - Calcul des dates de déclenchement

    /// Pour une alerte donnée, retourne les dates futures où elle se déclencherait.
    private static func computeTriggerDates(
        alert: TideAlert,
        tideData: [TideData],
        sunTimes: [(sunrise: Date?, sunset: Date?)],
        now: Date,
        maxResults: Int
    ) -> [Date] {
        // Check if this alert has sun conditions
        let hasSunCondition = alert.conditions.contains { $0.type == .sunriseSunset }

        if hasSunCondition && !alert.conditions.contains(where: { $0.type != .sunriseSunset }) {
            // Pure sun-based alert (no tide conditions) → compute from sun times
            return computeSunTriggerDates(alert: alert, sunTimes: sunTimes, now: now, maxResults: maxResults)
        }

        // Stratégie standard : pour chaque marée future, vérifier si les conditions sont remplies
        let futureTides = tideData
            .filter { $0.date > now }
            .sorted { $0.date < $1.date }
            .prefix(20) // Regarder les 20 prochaines marées (~5 jours)

        var results: [Date] = []

        for tide in futureTides {
            guard results.count < maxResults else { break }

            // Pour chaque condition, calculer la date de déclenchement par rapport à cette marée
            let conditionDates = alert.conditions.compactMap { condition -> Date? in
                switch condition.type {
                case .sunriseSunset:
                    return sunTriggerDate(for: condition, nearTide: tide, sunTimes: sunTimes)
                default:
                    return triggerDate(for: condition, relativeTo: tide, allTides: tideData)
                }
            }

            guard !conditionDates.isEmpty else { continue }

            if alert.requireAllConditions {
                // TOUTES les conditions doivent être satisfaites pour cette marée
                // (compactMap sans nil ⇒ count identique ⇒ conditionDates[i] ↔ conditions[i]).
                guard conditionDates.count == alert.conditions.count else { continue }
                // Conditions TEMPORELLES (timeBefore/After, soleil) = définissent QUAND notifier ;
                // AMBIANTES (coef, hauteur) = filtre de validité (renvoient tide.date si OK).
                // L'ancien `max()` prenait la marée elle-même → le preset « surf » (coef>80
                // ET <2 h avant PM) sonnait À LA PM au lieu de 2 h avant.
                let temporal: [Date] = zip(alert.conditions, conditionDates).compactMap { cond, date in
                    switch cond.type {
                    case .timeBeforeTide, .timeAfterTide, .sunriseSunset, .tideWindow: return date
                    default: return nil
                    }
                }
                if let anchor = temporal.min() ?? conditionDates.max(), anchor > now {
                    results.append(anchor)
                }
            } else {
                // AU MOINS UNE condition
                for date in conditionDates where date > now {
                    results.append(date)
                }
            }
        }

        // Dédupliquer (fenêtre de 5 min)
        return deduplicateDates(results, windowSeconds: 300)
            .prefix(maxResults)
            .sorted()
    }

    /// Compute trigger dates for pure sunrise/sunset alerts
    private static func computeSunTriggerDates(
        alert: TideAlert,
        sunTimes: [(sunrise: Date?, sunset: Date?)],
        now: Date,
        maxResults: Int
    ) -> [Date] {
        var results: [Date] = []

        for sunDay in sunTimes {
            for condition in alert.conditions where condition.type == .sunriseSunset {
                guard let event = condition.sunEvent, let timing = condition.sunTiming else { continue }
                let refTime: Date?
                switch event {
                case .sunrise: refTime = sunDay.sunrise
                case .sunset:  refTime = sunDay.sunset
                }
                guard let ref = refTime else { continue }

                let offsetSeconds = (condition.sunOffsetMinutes ?? 0) * 60
                let triggerTime: Date
                switch timing {
                case .at:     triggerTime = ref
                case .before: triggerTime = ref.addingTimeInterval(-offsetSeconds)
                case .after:  triggerTime = ref.addingTimeInterval(offsetSeconds)
                }

                if triggerTime > now {
                    results.append(triggerTime)
                }
            }
        }

        return deduplicateDates(results, windowSeconds: 300)
            .prefix(maxResults)
            .sorted()
    }

    /// Sun trigger date near a specific tide (for combined alerts)
    private static func sunTriggerDate(
        for condition: AlertCondition,
        nearTide: TideData,
        sunTimes: [(sunrise: Date?, sunset: Date?)]
    ) -> Date? {
        guard let event = condition.sunEvent, let timing = condition.sunTiming else { return nil }

        // Find the sun time on the same day as the tide
        let tideDay = Calendar.current.startOfDay(for: nearTide.date)
        let sunDay = sunTimes.first { day in
            guard let sunrise = day.sunrise else { return false }
            return Calendar.current.isDate(sunrise, inSameDayAs: tideDay)
        }

        let refTime: Date?
        switch event {
        case .sunrise: refTime = sunDay?.sunrise
        case .sunset:  refTime = sunDay?.sunset
        }
        guard let ref = refTime else { return nil }

        let offsetSeconds = (condition.sunOffsetMinutes ?? 0) * 60
        switch timing {
        case .at:     return ref
        case .before: return ref.addingTimeInterval(-offsetSeconds)
        case .after:  return ref.addingTimeInterval(offsetSeconds)
        }
    }

    /// Retourne la date de déclenchement pour une condition relative à une marée donnée.
    private static func triggerDate(
        for condition: AlertCondition,
        relativeTo tide: TideData,
        allTides: [TideData]
    ) -> Date? {
        // Vérifier le filtre de type de marée
        if let tideType = condition.tideType, tide.isHighTide != tideType {
            return nil
        }

        switch condition.type {
        case .tideHeight:
            if evaluateValue(tide.height, condition: condition) {
                return tide.date
            }
            return nil

        case .tideCoefficient:
            guard tide.isHighTide, let coef = tide.coefficient else { return nil }
            if evaluateValue(Double(coef), condition: condition) {
                return tide.date
            }
            return nil

        case .timeBeforeTide:
            // For "between", notify at the start of the window (max value = earliest moment)
            let hoursBefore: Double
            if condition.operator1 == .between, let v2 = condition.value2 {
                hoursBefore = max(condition.value1, v2)
            } else {
                hoursBefore = condition.value1
            }
            return tide.date.addingTimeInterval(-hoursBefore * 3600)

        case .timeAfterTide:
            let hoursAfter: Double
            if condition.operator1 == .between, let v2 = condition.value2 {
                hoursAfter = min(condition.value1, v2)
            } else {
                hoursAfter = condition.value1
            }
            return tide.date.addingTimeInterval(hoursAfter * 3600)

        case .windSpeed, .windDirection, .windEstablishing:
            return nil   // vent → évaluation live (BGTask + WindEstablishingService), pas pré-programmée

        case .tideWindow:
            // Notifie au DÉBUT de la fenêtre (value1 h AVANT la marée du bon type).
            guard condition.tideType == nil || tide.isHighTide == condition.tideType else { return nil }
            return tide.date.addingTimeInterval(-condition.value1 * 3600)

        case .sunriseSunset:
            return nil // Handled separately
        }
    }

    /// Évalue une valeur mesurée contre une condition
    private static func evaluateValue(_ measured: Double, condition: AlertCondition) -> Bool {
        // Réutilise la logique canonique du modèle (`AlertCondition.compareValue`) au lieu d'en
        // garder une copie ici qui pourrait diverger.
        condition.compareValue(measured)
    }

    // MARK: - Forecast Alert (prévisionnel)

    /// Envoie une notification immédiate pour une alerte prévisionnelle (vent prévu dans N jours)
    static func sendForecastAlert(title: String, body: String, identifier: String) async {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "TIDE_FORECAST_ALERT"

        // Envoyer dans 2 secondes (délai min pour UNTimeIntervalNotificationTrigger)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(prefix)forecast.\(identifier)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            appLogger.info("NotificationScheduler: alerte prévisionnelle envoyée — \(title)")
        } catch {
            appLogger.error("NotificationScheduler: erreur alerte prévisionnelle: \(error.localizedDescription)")
        }
    }

    /// Déduplique les dates proches (fenêtre glissante)
    private static func deduplicateDates(_ dates: [Date], windowSeconds: TimeInterval) -> [Date] {
        var result: [Date] = []
        for date in dates.sorted() {
            if let last = result.last, date.timeIntervalSince(last) < windowSeconds {
                continue
            }
            result.append(date)
        }
        return result
    }
}
