//
//  TideAlertEvaluator.swift
//  Tide It
//
//  Orchestration d'évaluation des alertes, extrait de TideService :
//    - Vérification alertes "live" (marée actuelle + météo courante)
//    - Vérification alertes prévisionnelles (vent J+1 → J+3)
//    - Dispatch des actions via NotificationDispatcher
//
//  TideAlertEvaluator ne publie pas d'état. TideService lui passe les données
//  et met à jour son @Published `triggeredAlerts` à partir du résultat.
//

import Foundation
import CoreLocation
import os.log

@MainActor
final class TideAlertEvaluator {
    static let shared = TideAlertEvaluator()

    private init() {}

    /// Exécute une passe de vérification : alertes live + prévisionnelles.
    /// Retourne la liste des alertes déclenchées (vide si rien).
    /// Les actions (notification, son, vibration) sont dispatchées automatiquement.
    @discardableResult
    func evaluate(
        alertService: AlertService,
        port: Port,
        tideData: [TideData]
    ) async -> [TideAlert] {
        // Aucune alerte active pour ce port → ne PAS réveiller WeatherKit/réseau toutes les
        // 5 min pour rien (fetchWeather n'a pas de cache : chaque appel touchait WeatherKit).
        let relevant = alertService.alerts.filter { $0.isEnabled && ($0.port == nil || $0.port == port.id) }
        guard !relevant.isEmpty else { return [] }

        let weatherService = WeatherService.shared
        let location = CLLocation(latitude: port.latitude, longitude: port.longitude)

        // Charger météo actuelle + sunrise/sunset + stations de vent en parallèle
        async let sunTask = weatherService.getSunriseSunset(for: location)
        async let weatherTask: () = weatherService.fetchWeather(for: location)
        async let windTask: () = WindStationAggregator.shared.refresh(around: location.coordinate)

        _ = await weatherTask
        _ = await windTask
        let sunTimes = await sunTask

        // Vent observé temps réel (prioritaire sur la prévision WeatherKit dans les alertes)
        let observedWind = WindStationAggregator.shared.nearestReading(for: port)?.reading
        if let obs = observedWind {
            appLogger.info("[AlertEvaluator] Vent observé utilisé : \(obs.speedAvgKmh, privacy: .public) km/h (\(obs.ageLabel, privacy: .public))")
        }

        // 1) Alertes avec la météo actuelle + vent observé si dispo
        let alerts = alertService.checkAlerts(
            tideData: tideData,
            weatherData: weatherService.currentWeather,
            port: port.id,
            sunriseTime: sunTimes.sunrise,
            sunsetTime: sunTimes.sunset,
            observedWind: observedWind
        )

        if !alerts.isEmpty {
            await dispatch(alerts)
        }

        // 2) Alertes vent en mode prévisionnel (J+1 à J+3 — observation temps réel non applicable)
        await checkForecastAlerts(alertService: alertService, port: port)

        return alerts
    }

    /// Dispatche les actions configurées pour chaque alerte déclenchée.
    private func dispatch(_ alerts: [TideAlert]) async {
        // Notifications = 100 % premium (notif / son / vibration). Le gratuit garde ses
        // alertes mais rien n'est délivré tant qu'il n'est pas abonné. Échoue FERMÉ.
        guard PremiumManager.shared.isPremium else { return }
        for alert in alerts {
            for action in alert.actions {
                await NotificationDispatcher.shared.execute(action: action, for: alert)
            }
        }
    }

    /// Vérifie les alertes vent sur les prévisions J+1 à J+3 (throttle 1h/port, cooldown 24h/alerte).
    private func checkForecastAlerts(alertService: AlertService, port: Port) async {
        // Notifications prévisionnelles = premium aussi (échoue FERMÉ).
        guard PremiumManager.shared.isPremium else { return }
        let forecastCheckKey = "lastForecastAlertCheck_\(port.id)"
        if let lastCheck = UserDefaults.standard.object(forKey: forecastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 3600 {
            return
        }
        UserDefaults.standard.set(Date(), forKey: forecastCheckKey)

        let windAlerts = alertService.alerts.filter { alert in
            guard alert.isEnabled,
                  (alert.port == nil || alert.port == port.id),
                  alert.conditions.contains(where: { $0.type == .windSpeed }) else { return false }
            // En combinaison ET avec d'autres conditions (coef, hauteur, soleil), on ne peut
            // PAS vérifier les autres conditions sur une prévision J+1..J+3 → on évite une
            // « Alerte vent » trompeuse (ex. preset « Sortie pêche idéale » : coef 70-90 ET
            // vent < 20 → sonnait dès qu'une journée était calme, coef ignoré).
            if alert.requireAllConditions && alert.conditions.contains(where: { $0.type != .windSpeed }) {
                return false
            }
            return true
        }
        guard !windAlerts.isEmpty else { return }

        let forecasts = await MarineWeatherService.shared.fetchHourlyForecast(for: port)
        guard !forecasts.isEmpty else { return }

        let calendar = Calendar.current
        let now = Date()

        for alert in windAlerts {
            let forecastCooldownKey = "forecastAlert_\(alert.id)"
            if let lastForecast = UserDefaults.standard.object(forKey: forecastCooldownKey) as? Date,
               now.timeIntervalSince(lastForecast) < 86400 {
                continue
            }

            for condition in alert.conditions where condition.type == .windSpeed {
                for dayOffset in 1...3 {
                    guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                    let dayStart = calendar.startOfDay(for: targetDay)
                    guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

                    let dayForecasts = forecasts.filter { $0.time >= dayStart && $0.time < dayEnd }
                    guard let maxWind = dayForecasts.max(by: { $0.windSpeedKmh < $1.windSpeedKmh }) else { continue }

                    // value1 stocké en km/h (canonical interne) — compare km/h → km/h
                    let windKmh = maxWind.windSpeedKmh
                    let userUnit = WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh

                    let triggered: Bool
                    switch condition.operator1 {
                    case .greaterThan: triggered = windKmh > condition.value1
                    case .lessThan: triggered = windKmh < condition.value1
                    case .equals: triggered = abs(windKmh - condition.value1) < 2
                    case .between: triggered = windKmh >= condition.value1 && windKmh <= (condition.value2 ?? condition.value1)
                    }

                    if triggered {
                        let dayName = dayOffset == 1 ? "demain" : "dans \(dayOffset) jours"
                        let formatter = DateFormatter()
                        formatter.dateFormat = "HH:mm"
                        formatter.timeZone = TimeZone(identifier: port.portTimeZoneIdentifier) ?? .current
                        let timeStr = formatter.string(from: maxWind.time)

                        // Titre adapté à l'opérateur : « vent faible » pour < (fenêtre calme),
                        // « vent fort » sinon — sinon un seuil bas affichait « Alerte vent » alarmiste.
                        let title = condition.operator1 == .lessThan
                            ? "Vent faible prévu \(dayName)"
                            : "Alerte vent prévue \(dayName)"

                        await NotificationScheduler.sendForecastAlert(
                            title: title,
                            body: "\(port.name) : vent prévu \(UnitFormatter.windSpeed(maxWind.windSpeedKmh, unit: userUnit)) vers \(timeStr)",
                            identifier: "forecast_\(alert.id)_\(dayOffset)"
                        )

                        UserDefaults.standard.set(Date(), forKey: forecastCooldownKey)
                        break
                    }
                }
            }
        }
    }
}
