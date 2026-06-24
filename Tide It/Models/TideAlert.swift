import Foundation
import SwiftUI
import WeatherKit
import CoreLocation

/// Décode un élément en tolérant l'échec (→ `value == nil`) : permet de décoder un
/// tableau sans tout perdre si un seul élément a un format obsolète.
struct LossyDecode<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Types de conditions
enum AlertConditionType: String, CaseIterable, Identifiable, Codable {
    case tideHeight = "Hauteur d'eau"
    case tideCoefficient = "Coefficient"
    case timeBeforeTide = "Temps avant marée"
    case timeAfterTide = "Temps après marée"
    case tideWindow = "Fenêtre de marée"
    case windSpeed = "Force du vent"
    case windDirection = "Direction du vent"
    case sunriseSunset = "Lever / Coucher"
    /// Alerte INTELLIGENTE : la balise franchit un seuil ET le vent s'établit (se maintient
    /// sur une fenêtre de confirmation). value1 = seuil (km/h), value2 = minutes de confirmation.
    /// Évaluée par `WindEstablishingService` (machine à états), pas par `isSatisfied`.
    case windEstablishing = "Le vent s'établit"

    var id: String { rawValue }

    /// Libellé localisé (la `rawValue` française reste l'identité persistée/Codable).
    var localizedName: String {
        switch self {
        case .tideHeight:      return String(localized: "Hauteur d'eau")
        case .tideCoefficient: return String(localized: "Coefficient")
        case .timeBeforeTide:  return String(localized: "Temps avant marée")
        case .timeAfterTide:   return String(localized: "Temps après marée")
        case .tideWindow:      return String(localized: "Avant/après marée")
        case .windSpeed:       return String(localized: "Force du vent")
        case .windDirection:   return String(localized: "Direction du vent")
        case .sunriseSunset:   return String(localized: "Lever / Coucher")
        case .windEstablishing: return String(localized: "Le vent s'établit")
        }
    }

    var icon: String {
        switch self {
        case .tideHeight:      return "water.waves"
        case .tideCoefficient: return "chart.bar.fill"
        case .timeBeforeTide:  return "timer"
        case .timeAfterTide:   return "timer.circle"
        case .tideWindow:      return "arrow.left.and.right.circle.fill"
        case .windSpeed:       return "wind"
        case .windDirection:   return "location.north.fill"
        case .sunriseSunset:   return "sunrise.fill"
        case .windEstablishing: return "wind.snow"
        }
    }
}

// MARK: - Opérateurs
enum ConditionOperator: String, CaseIterable, Identifiable, Codable {
    case greaterThan = "supérieur à"
    case lessThan = "inférieur à"
    case equals = "égal à"
    case between = "entre"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .greaterThan: return String(localized: "supérieur à")
        case .lessThan:    return String(localized: "inférieur à")
        case .equals:      return String(localized: "égal à")
        case .between:     return String(localized: "entre")
        }
    }

    var operatorSymbol: String {
        switch self {
        case .greaterThan: return ">"
        case .lessThan:    return "<"
        case .equals:      return "="
        case .between:     return "↔︎"
        }
    }
}

// MARK: - Événement solaire pour condition sunrise/sunset
enum SunEvent: String, Codable, CaseIterable, Identifiable {
    case sunrise = "Lever du soleil"
    case sunset = "Coucher du soleil"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .sunrise: return String(localized: "Lever du soleil")
        case .sunset:  return String(localized: "Coucher du soleil")
        }
    }

    var icon: String {
        switch self {
        case .sunrise: return "sunrise.fill"
        case .sunset:  return "sunset.fill"
        }
    }
}

enum SunTiming: String, Codable, CaseIterable, Identifiable {
    case before = "Avant"
    case after = "Après"
    case at = "Au moment"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .before: return String(localized: "Avant")
        case .after:  return String(localized: "Après")
        case .at:     return String(localized: "Au moment")
        }
    }

    var icon: String {
        switch self {
        case .before: return "backward.fill"
        case .after:  return "forward.fill"
        case .at:     return "equal.circle.fill"
        }
    }
}

// MARK: - Condition d'alerte
struct AlertCondition: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var type: AlertConditionType
    var operator1: ConditionOperator
    var value1: Double
    var value2: Double?
    var tideType: Bool? // true = PM, false = BM, nil = les deux
    var windDirectionRange: ClosedRange<Double>?

    // Wind direction: center + spread model
    var windDirectionCenter: Double?  // Direction d'origine du vent (0-360°)
    var windDirectionSpread: Double?  // Tolérance ± en degrés

    // Sunrise/Sunset fields
    var sunEvent: SunEvent?
    var sunTiming: SunTiming?
    var sunOffsetMinutes: Double?  // Offset in minutes (used with sunTiming)

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    // ⚠️ Égalité par VALEUR (pas seulement par id). Avant, `==` ne comparait que l'`id` :
    // éditer une condition (même UUID, ex. la hauteur d'eau passe de 3→2) la laissait « égale »,
    // donc `byPort`/les vues `.equatable()` ne voyaient AUCUN changement → ni le calendrier GO
    // ni les rectangles du mode vent ne se rafraîchissaient. On compare désormais tous les champs.
    // (Le `hash` reste sur `id` : valide car `==` implique désormais le même `id`. Aucun
    // `Set<AlertCondition>`/clé de dictionnaire n'existe — vérifié — donc aucun effet de bord.)
    static func == (lhs: AlertCondition, rhs: AlertCondition) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.operator1 == rhs.operator1 &&
        lhs.value1 == rhs.value1 &&
        lhs.value2 == rhs.value2 &&
        lhs.tideType == rhs.tideType &&
        lhs.windDirectionRange == rhs.windDirectionRange &&
        lhs.windDirectionCenter == rhs.windDirectionCenter &&
        lhs.windDirectionSpread == rhs.windDirectionSpread &&
        lhs.sunEvent == rhs.sunEvent &&
        lhs.sunTiming == rhs.sunTiming &&
        lhs.sunOffsetMinutes == rhs.sunOffsetMinutes
    }

    init(id: UUID = UUID(), type: AlertConditionType, operator1: ConditionOperator, value1: Double,
         value2: Double? = nil, tideType: Bool? = nil, windDirectionRange: ClosedRange<Double>? = nil,
         windDirectionCenter: Double? = nil, windDirectionSpread: Double? = nil,
         sunEvent: SunEvent? = nil, sunTiming: SunTiming? = nil, sunOffsetMinutes: Double? = nil) {
        self.id = id
        self.type = type
        self.operator1 = operator1
        self.value1 = value1
        self.value2 = value2
        self.tideType = tideType
        self.windDirectionRange = windDirectionRange
        self.windDirectionCenter = windDirectionCenter
        self.windDirectionSpread = windDirectionSpread
        self.sunEvent = sunEvent
        self.sunTiming = sunTiming
        self.sunOffsetMinutes = sunOffsetMinutes
    }

    // MARK: - Source du vent (réel vs prévu)

    /// Vrai si l'évaluation s'appuie sur le vent (donc potentiellement la balise réelle).
    var usesWindSource: Bool {
        type == .windSpeed || type == .windDirection || type == .windEstablishing
    }

    /// Libellé de la source de vent, pour distinguer le réel (balise) du prévu (Apple) dans l'UI.
    var windSourceLabel: String {
        switch type {
        case .windEstablishing:        return "confirmé en temps réel (balise)"
        case .windSpeed, .windDirection: return "vent réel (balise) si dispo, sinon prévu"
        default:                       return ""
        }
    }

    // MARK: - Évaluation
    /// - Parameter observedWind: Lecture de vent MESURÉE en temps réel (anémomètre à
    ///   proximité du port). Si présente et fraîche, elle est prioritaire sur
    ///   `weatherData` (prévision WeatherKit) pour les conditions de vent.
    func isSatisfied(tideData: [TideData], weatherData: CurrentWeather?, currentTime: Date,
                     sunriseTime: Date? = nil, sunsetTime: Date? = nil,
                     observedWind: WindReading? = nil) -> Bool {
        switch type {
        case .tideHeight:      return checkTideHeightCondition(tideData: tideData, currentTime: currentTime)
        case .tideCoefficient: return checkTideCoefficientCondition(tideData: tideData, currentTime: currentTime)
        case .timeBeforeTide:  return checkTimeBeforeTideCondition(tideData: tideData, currentTime: currentTime)
        case .timeAfterTide:   return checkTimeAfterTideCondition(tideData: tideData, currentTime: currentTime)
        case .tideWindow:      return checkTideWindowCondition(tideData: tideData, currentTime: currentTime)
        case .windSpeed:       return checkWindSpeedCondition(weatherData: weatherData, observedWind: observedWind)
        case .windDirection:   return checkWindDirectionCondition(weatherData: weatherData, observedWind: observedWind)
        case .sunriseSunset:   return checkSunriseSunsetCondition(currentTime: currentTime, sunrise: sunriseTime, sunset: sunsetTime)
        case .windEstablishing: return false   // stateful → géré par WindEstablishingService
        }
    }

    // MARK: - Helpers privés — compareValue centralisé (DRY)

    /// Compare une valeur mesuree a la condition selon `operator1`/`value1`/`value2`.
    /// Internal (plus private) : `NotificationScheduler` le reutilise au lieu de dupliquer la logique.
    func compareValue(_ measured: Double) -> Bool {
        switch operator1 {
        case .greaterThan:
            return measured > value1
        case .lessThan:
            return measured < value1
        case .equals:
            return abs(measured - value1) < 0.1
        case .between:
            guard let v2 = value2 else { return false }
            return measured >= min(value1, v2) && measured <= max(value1, v2)
        }
    }

    private func checkTideHeightCondition(tideData: [TideData], currentTime: Date) -> Bool {
        // PM/BM précisé → sémantique « hauteur de la PROCHAINE pleine/basse mer » (utile pour une
        // alerte « la prochaine PM ≥ X »). On garde le comportement historique dans ce cas.
        if let wantHigh = tideType {
            let next = tideData.filter { $0.date > currentTime && $0.isHighTide == wantHigh }
                .sorted { $0.date < $1.date }.first
            guard let h = next?.height else { return false }
            return compareValue(h)
        }
        // « Les deux » (cas des activités / hauteur d'eau pour naviguer) → on compare la HAUTEUR
        // INSTANTANÉE réelle à cet instant (= exactement ce que montre la courbe), par
        // interpolation cosinus entre les extrêmes encadrants. Avant, on comparait la hauteur du
        // PROCHAIN extrême → faux entre deux marées (ex. niveau réel 0,5 m mais condition vraie
        // car la PM à venir fait 4 m). C'est la cause du « pas très juste ».
        guard let level = TideCalculator.interpolatedHeight(at: currentTime, tides: tideData) else { return false }
        return compareValue(level)
    }

    private func checkTideCoefficientCondition(tideData: [TideData], currentTime: Date) -> Bool {
        let nextHighTides = tideData.filter {
            $0.date > currentTime && $0.isHighTide && $0.coefficient != nil
        }.sorted { $0.date < $1.date }
        guard let coef = nextHighTides.first?.coefficient else { return false }
        return compareValue(Double(coef))
    }

    private func checkTimeBeforeTideCondition(tideData: [TideData], currentTime: Date) -> Bool {
        let nextTides = tideData.filter {
            $0.date > currentTime && (tideType == nil || $0.isHighTide == tideType)
        }.sorted { $0.date < $1.date }
        guard let nextTide = nextTides.first else { return false }
        return compareValue(nextTide.date.timeIntervalSince(currentTime) / 3600)
    }

    private func checkTimeAfterTideCondition(tideData: [TideData], currentTime: Date) -> Bool {
        let previousTides = tideData.filter {
            $0.date < currentTime && (tideType == nil || $0.isHighTide == tideType)
        }.sorted { $0.date > $1.date }
        guard let prevTide = previousTides.first else { return false }
        return compareValue(currentTime.timeIntervalSince(prevTide.date) / 3600)
    }

    /// Fenêtre AUTOUR d'une marée : vrai si `currentTime` ∈ [marée − value1 h ; marée + value2 h]
    /// pour une PM/BM (ou les deux). UNE condition gère AVANT et APRÈS (ex. ±3 h autour de la PM).
    /// Combiner « temps avant » ET « temps après » couvrait au contraire tout le cycle (~12 h) →
    /// d'où le bug. `value1` = heures avant, `value2` = heures après (défaut = value1 si absent).
    private func checkTideWindowCondition(tideData: [TideData], currentTime: Date) -> Bool {
        let before = value1 * 3600
        let after = (value2 ?? value1) * 3600
        for tide in tideData where tideType == nil || tide.isHighTide == tideType {
            if currentTime >= tide.date.addingTimeInterval(-before),
               currentTime <= tide.date.addingTimeInterval(after) {
                return true
            }
        }
        return false
    }

    private func checkWindSpeedCondition(weatherData: CurrentWeather?, observedWind: WindReading?) -> Bool {
        // Priorité au vent observé (mesure temps réel) si fraîche
        let speedKmh: Double
        if let observed = observedWind, observed.isFresh {
            speedKmh = observed.speedAvgKmh
        } else if let weather = weatherData {
            speedKmh = weather.wind.speed.converted(to: .kilometersPerHour).value
        } else {
            return false
        }
        // value1 est stocké en km/h (canonical interne). Compare km/h → km/h.
        return compareValue(speedKmh)
    }

    private func checkWindDirectionCondition(weatherData: CurrentWeather?, observedWind: WindReading?) -> Bool {
        // Priorité au vent observé (mesure temps réel) si fraîche
        let direction: Double
        if let observed = observedWind, observed.isFresh {
            direction = observed.directionDegrees
        } else if let weather = weatherData {
            direction = weather.wind.direction.converted(to: .degrees).value
        } else {
            return false
        }

        // New center + spread model
        if let center = windDirectionCenter, let spread = windDirectionSpread {
            let diff = angleDifference(direction, center)
            return diff <= spread
        }

        // Legacy: ClosedRange model
        if let range = windDirectionRange {
            return range.contains(direction)
        }

        // Fallback: cône traversant 0°
        let start = value1
        let end = value2 ?? value1
        return direction >= start || direction <= end
    }

    /// Smallest angular difference between two compass bearings (0-180°)
    private func angleDifference(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    private func checkSunriseSunsetCondition(currentTime: Date, sunrise: Date?, sunset: Date?) -> Bool {
        guard let event = sunEvent, let timing = sunTiming else { return false }

        let referenceTime: Date?
        switch event {
        case .sunrise: referenceTime = sunrise
        case .sunset:  referenceTime = sunset
        }

        guard let refTime = referenceTime else { return false }

        let offsetSeconds = (sunOffsetMinutes ?? 0) * 60

        switch timing {
        case .at:
            // Within 5 minutes of the event
            return abs(currentTime.timeIntervalSince(refTime)) <= 300
        case .before:
            // Check if current time is within the "before" window
            let triggerTime = refTime.addingTimeInterval(-offsetSeconds)
            return abs(currentTime.timeIntervalSince(triggerTime)) <= 300
        case .after:
            let triggerTime = refTime.addingTimeInterval(offsetSeconds)
            return abs(currentTime.timeIntervalSince(triggerTime)) <= 300
        }
    }

}

// MARK: - Types d'actions
enum AlertActionType: String, CaseIterable, Identifiable, Codable {
    case notification = "Notification"
    case sound = "Son"
    case vibration = "Vibration"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .notification: return String(localized: "Notification")
        case .sound:        return String(localized: "Son")
        case .vibration:    return String(localized: "Vibration")
        }
    }

    var icon: String {
        switch self {
        case .notification: return "bell.fill"
        case .sound:        return "speaker.wave.2.fill"
        case .vibration:    return "waveform"
        }
    }
}

// MARK: - Action d'alerte
struct AlertAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: AlertActionType
    var message: String?
    var soundName: String?
    var vibrationPattern: String?
}

// MARK: - Alerte complète
struct TideAlert: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled: Bool = true
    var conditions: [AlertCondition] = []
    var actions: [AlertAction] = []
    var port: String?
    var portName: String?
    var requireAllConditions: Bool = true
    var lastTriggered: Date?
    var cooldownPeriod: TimeInterval = 3600

    func shouldTrigger(tideData: [TideData], weatherData: CurrentWeather?, currentTime: Date,
                       sunriseTime: Date? = nil, sunsetTime: Date? = nil,
                       observedWind: WindReading? = nil) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }

        // Cooldown check
        if let last = lastTriggered, currentTime.timeIntervalSince(last) < cooldownPeriod {
            return false
        }

        if requireAllConditions {
            return conditions.allSatisfy {
                $0.isSatisfied(tideData: tideData, weatherData: weatherData, currentTime: currentTime,
                              sunriseTime: sunriseTime, sunsetTime: sunsetTime,
                              observedWind: observedWind)
            }
        } else {
            return conditions.contains {
                $0.isSatisfied(tideData: tideData, weatherData: weatherData, currentTime: currentTime,
                              sunriseTime: sunriseTime, sunsetTime: sunsetTime,
                              observedWind: observedWind)
            }
        }
    }
}

// MARK: - Service de gestion des alertes
@MainActor
class AlertService: ObservableObject {
    static let alertsDidChangeNotification = Notification.Name("TideAlertServiceDidChange")

    @Published var alerts: [TideAlert] = []
    private let storageKey = "savedTideAlerts"
    private var didLoadInitialData = false

    init() {
        loadAlerts()
        // Le store peut être muté HORS de cette instance (background : `markTriggeredInStore` écrit
        // le `lastTriggered` sur disque + poste cette notif). On se resynchronise, sinon on garde un
        // `lastTriggered` périmé en mémoire → cooldown faux en avant-plan. `reloadAlerts()` existait déjà.
        // La closure d'observateur est @Sendable (pas @MainActor) → on saute explicitement sur le
        // main actor pour appeler `reloadAlerts()` (@MainActor). `queue: .main` garantit déjà le thread.
        NotificationCenter.default.addObserver(
            forName: Self.alertsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reloadAlerts() } }
    }

    func addAlert(_ alert: TideAlert) {
        guard !alert.name.isEmpty, !alert.conditions.isEmpty else {
            appLogger.warning("Tentative d'ajout d'une alerte invalide (nom vide ou sans conditions)")
            return
        }
        alerts.append(alert)
        saveAlerts()
    }

    func updateAlert(_ alert: TideAlert) {
        guard !alert.name.isEmpty, !alert.conditions.isEmpty else {
            appLogger.warning("Tentative de mise à jour avec une alerte invalide")
            return
        }
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = alert
            saveAlerts()
        } else {
            addAlert(alert)
        }
    }

    func removeAlert(id: UUID) {
        alerts.removeAll { $0.id == id }
        saveAlerts()
    }

    /// Supprime toutes les alertes liées à un port (à sa suppression) et renvoie leurs id, pour
    /// que l'appelant annule leurs notifications programmées + purge leurs cooldowns/états.
    @discardableResult
    func removeAlerts(forPort portId: String) -> [UUID] {
        let removed = alerts.filter { $0.port == portId }.map { $0.id }
        guard !removed.isEmpty else { return [] }
        alerts.removeAll { $0.port == portId }
        saveAlerts()
        return removed
    }

    func toggleAlert(id: UUID) {
        if let index = alerts.firstIndex(where: { $0.id == id }) {
            alerts[index].isEnabled.toggle()
            saveAlerts()
        }
    }

    func alertTriggered(id: UUID) {
        if let index = alerts.firstIndex(where: { $0.id == id }) {
            alerts[index].lastTriggered = Date()
            saveAlerts()
        }
    }

    /// Marque une alerte comme déclenchée DIRECTEMENT dans le store persistant, sans
    /// instance vivante (appelé depuis le delegate de notifications quand l'utilisateur
    /// ouvre une notification programmée — démarre le cooldown même app fermée).
    static func markTriggeredInStore(id: UUID) {
        let key = "savedTideAlerts"
        guard let data = UserDefaults.standard.data(forKey: key),
              var alerts = try? JSONDecoder().decode([TideAlert].self, from: data),
              let idx = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[idx].lastTriggered = Date()
        if let encoded = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(encoded, forKey: key)
            NotificationCenter.default.post(name: AlertService.alertsDidChangeNotification, object: nil)
        }
    }

    func checkAlerts(tideData: [TideData], weatherData: CurrentWeather?, port: String?,
                     sunriseTime: Date? = nil, sunsetTime: Date? = nil,
                     observedWind: WindReading? = nil) -> [TideAlert] {
        let currentTime = Date()
        let triggered = alerts.filter { alert in
            guard alert.isEnabled else { return false }
            if let alertPort = alert.port, let currentPort = port, alertPort != currentPort { return false }
            return alert.shouldTrigger(tideData: tideData, weatherData: weatherData, currentTime: currentTime,
                                      sunriseTime: sunriseTime, sunsetTime: sunsetTime,
                                      observedWind: observedWind)
        }

        for alert in triggered {
            alertTriggered(id: alert.id)
        }

        return triggered
    }

    // MARK: - Persistence

    private func saveAlerts() {
        do {
            let data = try JSONEncoder().encode(alerts)
            UserDefaults.standard.set(data, forKey: storageKey)
            appLogger.debug("Alertes sauvegardées: \(self.alerts.count)")
            NotificationCenter.default.post(name: Self.alertsDidChangeNotification, object: nil)
        } catch {
            appLogger.error("Erreur sauvegarde alertes: \(error.localizedDescription)")
        }
    }

    private func loadAlerts() {
        guard !didLoadInitialData else { return }
        defer { didLoadInitialData = true }

        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            appLogger.info("Aucune alerte en cache — initialisation vide")
            alerts = []
            return
        }

        do {
            alerts = try JSONDecoder().decode([TideAlert].self, from: data)
            appLogger.info("Alertes chargées: \(self.alerts.count)")
        } catch {
            // Décodage TOLÉRANT : si UNE alerte a un format obsolète (migration de modèle),
            // on ne perd pas TOUTES les autres. Et on NE SUPPRIME PAS le store (une future
            // version pourrait re-décoder ce qui a échoué ici).
            let recovered = (try? JSONDecoder().decode([LossyDecode<TideAlert>].self, from: data))?
                .compactMap(\.value) ?? []
            alerts = recovered
            if recovered.isEmpty {
                appLogger.error("Erreur décodage alertes (aucune récupérable): \(error.localizedDescription)")
            } else {
                appLogger.warning("Alertes : \(recovered.count) récupérées, certaines ignorées (format obsolète)")
            }
        }
    }

    func reloadAlerts() {
        didLoadInitialData = false
        loadAlerts()
    }
}
