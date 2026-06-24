//
//  WindEstablishingService.swift
//  Tide It
//
//  Alerte INTELLIGENTE « le vent s'établit » : quand la balise franchit le seuil ET que le
//  vent SE MAINTIENT sur une fenêtre de confirmation, on notifie. Une rafale isolée qui
//  retombe ne déclenche RIEN (pas de fausse alerte, pas de route pour rien).
//
//  Machine à états persistée (UserDefaults) → survit aux réveils en arrière-plan.
//  Évaluée en AVANT-PLAN (à chaque nouvelle mesure balise + check 5 min) ET en
//  ARRIÈRE-PLAN (BGAppRefreshTask). En background, la cadence des réveils est dictée par
//  iOS (opportuniste) : la confirmation peut donc prendre plus que la fenêtre demandée — on
//  l'évalue dès qu'un réveil survient après le délai, sur la dernière mesure dispo.
//

import Foundation
import CoreLocation

@MainActor
final class WindEstablishingService {
    static let shared = WindEstablishingService()
    private init() {}

    private let pendingKey = "windEstab.pending"   // [alertId: detectedAt timeIntervalSince1970]
    private let portKey = "windEstab.port"         // snapshot du port suivi (pour le background)

    /// État « franchissement détecté à T0 » par alerte (persisté → survit au background).
    private var pending: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
    }

    private static func loadAlerts() -> [TideAlert] {
        guard let data = UserDefaults.standard.data(forKey: "savedTideAlerts"),
              let alerts = try? JSONDecoder().decode([TideAlert].self, from: data) else { return [] }
        return alerts
    }

    /// Au moins une alerte « le vent s'établit » active ? → active le rafraîchissement balise.
    static func hasActiveAlert(forPort portId: String? = nil) -> Bool {
        loadAlerts().contains { a in
            a.isEnabled
            && a.conditions.contains { $0.type == .windEstablishing }
            && (a.port == nil || portId == nil || a.port == portId)
        }
    }

    /// Mémorise le port suivi (id/nom/coordonnées) pour pouvoir évaluer en ARRIÈRE-PLAN
    /// sans recharger tout le catalogue de ports.
    static func setMonitoredPort(id: String, name: String, latitude: Double, longitude: Double) {
        UserDefaults.standard.set(["id": id, "name": name, "lat": latitude, "lon": longitude], forKey: "windEstab.port")
    }

    /// Point d'entrée ARRIÈRE-PLAN (BGAppRefreshTask) : rafraîchit la balise du port suivi,
    /// puis avance la machine à états. La cadence des réveils est dictée par iOS.
    func evaluateInBackground(now: Date = Date()) async {
        guard Self.hasActiveAlert(),
              let p = UserDefaults.standard.dictionary(forKey: portKey),
              let id = p["id"] as? String, let name = p["name"] as? String,
              let lat = p["lat"] as? Double, let lon = p["lon"] as? Double else { return }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        await WindStationAggregator.shared.refresh(around: coord, force: true)
        let reading = WindStationAggregator.shared.nearestReading(forCoordinate: coord)
        await evaluate(reading: reading, portId: id, portName: name, now: now)
    }

    /// Y a-t-il une confirmation EN COURS (pour l'afficher dans l'UI) ? → (alerteNom, détectéLe).
    func activePending() -> (name: String, since: Date)? {
        let pend = pending
        guard let (idStr, t0) = pend.min(by: { $0.value < $1.value }) else { return nil }
        guard let alert = Self.loadAlerts().first(where: { $0.id.uuidString == idStr }) else { return nil }
        return (alert.name, Date(timeIntervalSince1970: t0))
    }

    /// Évalue les alertes « le vent s'établit » du port contre la mesure balise (machine à états).
    func evaluate(reading: WindReading?, portId: String?, portName: String?, now: Date = Date()) async {
        let alerts = Self.loadAlerts().filter { a in
            a.isEnabled
            && a.conditions.contains { $0.type == .windEstablishing }
            && (a.port == nil || a.port == portId)
        }
        var pend = pending
        // Purge des états orphelins (alerte supprimée/désactivée).
        let liveIds = Set(alerts.map(\.id.uuidString))
        pend = pend.filter { liveIds.contains($0.key) }

        for alert in alerts {
            guard let cond = alert.conditions.first(where: { $0.type == .windEstablishing }) else { continue }
            let key = alert.id.uuidString
            let threshold = cond.value1                         // km/h
            let confirmSec = max(60, (cond.value2 ?? 20) * 60)  // fenêtre de confirmation

            // Cooldown : on n'arme pas tant que l'alerte est en pause anti-spam.
            if let last = alert.lastTriggered, now.timeIntervalSince(last) < alert.cooldownPeriod {
                pend[key] = nil
                continue
            }

            let fresh = reading?.isFresh ?? false
            let speed = reading?.speedAvgKmh ?? 0
            let directionOK: Bool = {
                guard let center = cond.windDirectionCenter, let spread = cond.windDirectionSpread,
                      let d = reading?.directionDegrees else { return true }
                let raw = ((d - center).truncatingRemainder(dividingBy: 360) + 540)
                    .truncatingRemainder(dividingBy: 360) - 180
                return abs(raw) <= spread
            }()
            let above = fresh && speed >= threshold && directionOK

            if above {
                if let t0 = pend[key] {
                    if now.timeIntervalSince1970 - t0 >= confirmSec {
                        await fire(alert: alert, speed: speed, now: now)   // confirmé → notif
                        pend[key] = nil
                    }
                    // sinon : toujours en attente de confirmation
                } else {
                    pend[key] = now.timeIntervalSince1970                  // franchissement détecté
                }
            } else {
                pend[key] = nil   // retombé / mesure pas fraîche → on annule (silence)
            }
        }
        pending = pend
    }

    private func fire(alert: TideAlert, speed: Double, now: Date) async {
        // Notifications = 100 % premium (échoue FERMÉ). Le gratuit peut armer l'alerte
        // « le vent s'établit » mais ne reçoit aucune notification (cf. modèle premium).
        guard PremiumManager.shared.isPremium else { return }
        let unit = WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
        let spot = alert.portName ?? alert.name
        await NotificationDispatcher.shared.send(
            title: String(localized: "Le vent s'établit — fonce"),
            body: String(localized: "\(UnitFormatter.windSpeed(speed, unit: unit)) soutenu à \(spot). C'est parti.")
        )
        AlertService.markTriggeredInStore(id: alert.id)
        appLogger.info("[WindEstablishing] Confirmé pour \(alert.name) : \(Int(speed)) km/h")
    }

    // MARK: - Fenêtres de GO par spot (notif « fenêtre GO ici ») ────────────────────────────
    //
    //  Règle voulue : on ne notifie une fenêtre de GO QUE si (1) une BALISE de vent réel est
    //  proche ET (2) le vent du sport est ÉTABLI sur 20 min (mesure soutenue, pas une rafale).
    //  C'est la BALISE qui dicte → la notif peut tomber un peu avant/après la fenêtre prévue par
    //  le calendrier (qui, lui, est bâti sur la prévision). Même machine à états que ci-dessus,
    //  mais clé = « portId|sport ». Évaluée en arrière-plan (BGTask, cadence iOS = douce pour la
    //  batterie) et en avant-plan (port sélectionné, sans réseau supplémentaire).
    //
    //  Périmètre du DÉCLENCHEUR : conditions de VENT du sport (force + direction), seul signal
    //  réellement « live » via balise. Les conditions de marée/hauteur d'eau restent du ressort
    //  du calendrier (prévision) — non rejouables hors-ligne pour un spot non sélectionné.

    private let goPendingKey = "goWindow.pending"     // ["portId|sport": detectedAt]
    private let goFiredKey   = "goWindow.lastFired"   // ["portId|sport": firedAt] (anti-spam)
    private let goCoordsKey  = "goWindow.portCoords"  // [portId: [name/lat/lon]] (résolution background)
    private let goConfirmSec: TimeInterval = 20 * 60  // vent établi 20 min
    private let goCooldown:   TimeInterval = 3 * 3600 // une notif / spot+sport max toutes les 3 h

    private var goPending: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: goPendingKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: goPendingKey) }
    }
    private var goFired: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: goFiredKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: goFiredKey) }
    }

    /// Purge SYNCHRONE de tout l'état par-spot/par-alerte d'un port supprimé. Les notifs GO et
    /// « vent s'établit » partent via un identifiant UUID aléatoire + trigger 1 s → NON annulables
    /// après coup ; tuer l'état qui les régénère en arrière-plan est le seul correctif durable.
    func purge(portId: String, alertIds: [String] = []) {
        let prefix = "\(portId)|"
        goPending = goPending.filter { !$0.key.hasPrefix(prefix) }
        goFired   = goFired.filter   { !$0.key.hasPrefix(prefix) }
        var coords = (UserDefaults.standard.dictionary(forKey: goCoordsKey) as? [String: [String: Any]]) ?? [:]
        if coords.removeValue(forKey: portId) != nil {
            UserDefaults.standard.set(coords, forKey: goCoordsKey)
        }
        if !alertIds.isEmpty {
            var pend = pending
            for id in alertIds { pend.removeValue(forKey: id) }
            pending = pend
        }
        // Snapshot du port suivi « vent s'établit » : on l'efface s'il pointe le port supprimé.
        if let p = UserDefaults.standard.dictionary(forKey: portKey), (p["id"] as? String) == portId {
            UserDefaults.standard.removeObject(forKey: portKey)
        }
    }

    /// Snapshot léger portId → coordonnées, maintenu par `TideService` (favoris + sélectionné +
    /// spots à notifier). Permet de résoudre les coordonnées d'un spot en arrière-plan sans
    /// recharger tout le catalogue. La liste des spots à notifier, elle, est lue en direct dans
    /// `SportSetupStore` (UserDefaults) → activer/désactiver la notif ne nécessite pas de re-snapshot.
    static func setGoNotifyPortCoords(_ coords: [String: (name: String, lat: Double, lon: Double)]) {
        let map = coords.mapValues { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] as [String: Any] }
        UserDefaults.standard.set(map, forKey: "goWindow.portCoords")
    }

    /// Au moins un spot a la notif « fenêtre GO ici » active → vaut la peine d'évaluer en background.
    static func hasGoNotifySpots() -> Bool {
        SportSetupStore.shared.notifyEnabledPortIDs.contains {
            (UserDefaults.standard.dictionary(forKey: "goWindow.portCoords")?[$0]) != nil
        }
    }

    /// Point d'entrée ARRIÈRE-PLAN : pour chaque spot à notifier, rafraîchit SA balise puis avance
    /// la machine à états. Premium-only (évite tout coût batterie pour le gratuit, qui n'a pas de notif).
    func evaluateGoWindowsInBackground(now: Date = Date()) async {
        guard PremiumManager.shared.isPremium else { return }
        let coordsMap = (UserDefaults.standard.dictionary(forKey: goCoordsKey) as? [String: [String: Any]]) ?? [:]
        let spots = SportSetupStore.shared.notifyEnabledPortIDs
        guard !spots.isEmpty, !coordsMap.isEmpty else { return }
        // Sources GLOBALES rafraîchies UNE fois (identiques pour tous les spots) — évite de
        // refetch le gros fichier NDBC + Pioupiou /all par spot (N+1 = coût batterie inutile).
        await WindStationAggregator.shared.refreshGlobalOnly(force: true)
        for portId in spots {
            guard let meta = coordsMap[portId],
                  let name = meta["name"] as? String,
                  let lat = meta["lat"] as? Double, let lon = meta["lon"] as? Double else { continue }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            // Seules les sources GÉO (bbox/≤20 km) varient par spot → on ne refait qu'elles.
            await WindStationAggregator.shared.refreshGeo(around: coord, force: true)
            let reading = WindStationAggregator.shared.nearestReading(forCoordinate: coord)
            await evaluateGo(reading: reading, portId: portId, portName: name, lat: lat, lon: lon, now: now)
        }
    }

    /// Avance la machine à états « fenêtre GO » d'un spot contre une mesure balise.
    /// Sans balise FRAÎCHE → rien ne s'arme (gate « balise requise »). Réutilise le comparateur
    /// canonique `AlertCondition.isSatisfied` sur les conditions de VENT (mêmes unités/règles que
    /// le calendrier). Sûr à appeler pour le port sélectionné en avant-plan (gate notify interne).
    func evaluateGo(reading: WindReading?, portId: String, portName: String,
                    lat: Double? = nil, lon: Double? = nil, now: Date = Date()) async {
        var pend = goPending
        var fired = goFired
        guard SportSetupStore.shared.notify(for: portId) else {
            // Notif coupée pour ce spot → on purge ses états (attente + anti-spam + coords).
            // Auto-réparation : si une suppression a oublié d'appeler `purgePortState`, le
            // background se nettoie ici dès le 1er passage après extinction du toggle.
            let prefix = "\(portId)|"
            goPending = pend.filter { !$0.key.hasPrefix(prefix) }
            goFired   = fired.filter { !$0.key.hasPrefix(prefix) }
            var coords = (UserDefaults.standard.dictionary(forKey: goCoordsKey) as? [String: [String: Any]]) ?? [:]
            if coords.removeValue(forKey: portId) != nil { UserDefaults.standard.set(coords, forKey: goCoordsKey) }
            return
        }
        let sports = SportSetupStore.shared.enabledSetups(for: portId)
        let liveKeys = Set(sports.map { "\(portId)|\($0.sport.rawValue)" })
        // Purge des états orphelins (sport désactivé pour ce spot).
        pend = pend.filter { !$0.key.hasPrefix("\(portId)|") || liveKeys.contains($0.key) }

        let fresh = reading?.isFresh ?? false
        for setup in sports {
            let key = "\(portId)|\(setup.sport.rawValue)"

            // SURF : pas de balise de houle → on évalue les SurfConditions sur la PRÉVISION marine en
            // cache, à l'heure courante (jour uniquement). Pas de phase de confirmation (le forecast
            // ne fluctue pas comme le vent). Anti-spam 3 h comme le vent. Notif framée « (prévision) ».
            if setup.sport.isSurf {
                if let last = fired[key], now.timeIntervalSince1970 - last < goCooldown { pend[key] = nil; continue }
                var go = false
                if let lat, let lon { go = surfGoNow(setup: setup, lat: lat, lon: lon, now: now) }
                if go, let lat, let lon {
                    await fireSurfGo(setup: setup, spot: portName, lat: lat, lon: lon, now: now)
                    fired[key] = now.timeIntervalSince1970
                }
                pend[key] = nil
                continue
            }

            // Conditions de VENT uniquement (force + direction) — seul signal live via balise.
            let windConds = setup.conditions.filter { $0.type == .windSpeed || $0.type == .windDirection }
            // Exiger une condition de FORCE de vent : un sport avec seulement une direction serait
            // sinon « GO » à n'importe quelle vitesse (faux GO à ~3 km/h).
            guard windConds.contains(where: { $0.type == .windSpeed }), fresh, let r = reading else { pend[key] = nil; continue }
            let go = windConds.allSatisfy {
                $0.isSatisfied(tideData: [], weatherData: nil, currentTime: now, observedWind: r)
            }

            // Anti-spam : une notif par spot+sport toutes les 3 h.
            if let last = fired[key], now.timeIntervalSince1970 - last < goCooldown {
                if !go { pend[key] = nil }
                continue
            }
            if go {
                if let t0 = pend[key] {
                    if now.timeIntervalSince1970 - t0 >= goConfirmSec {
                        await fireGo(sport: setup.sport, spot: portName, speed: r.speedAvgKmh)
                        fired[key] = now.timeIntervalSince1970
                        pend[key] = nil
                    }   // sinon : confirmation en cours
                } else {
                    pend[key] = now.timeIntervalSince1970   // franchissement détecté
                }
            } else {
                pend[key] = nil   // pas (ou plus) GO → on annule
            }
        }
        // Purge `fired` des sports désactivés de ce spot : borne la croissance UserDefaults ET
        // permet à un sport réactivé de re-notifier sans cooldown fantôme.
        fired = fired.filter { !$0.key.hasPrefix("\(portId)|") || liveKeys.contains($0.key) }
        goPending = pend
        goFired = fired
    }

    private func fireGo(sport: WindSport, spot: String, speed: Double) async {
        guard PremiumManager.shared.isPremium else { return }
        let unit = WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
        await NotificationDispatcher.shared.send(
            title: String(localized: "Fenêtre de GO — \(sport.localizedName)"),
            body: String(localized: "\(UnitFormatter.windSpeed(speed, unit: unit)) établi à \(spot) (balise). C'est le moment.")
        )
        appLogger.info("[GoWindow] \(sport.rawValue) GO confirmé à \(spot) : \(Int(speed)) km/h")
    }

    /// La fenêtre SURF est-elle ouverte MAINTENANT ? Évalue les SurfConditions (ajustées au niveau)
    /// sur l'heure de prévision marine en cache la plus proche de `now`, de JOUR uniquement.
    /// Pas de marée en arrière-plan → le gate marée optionnel est ignoré (jamais de faux négatif).
    private func surfGoNow(setup: SportSetup, lat: Double, lon: Double, now: Date) -> Bool {
        // Jour seulement : pas de notif surf en pleine nuit.
        if let sun = SolarCalculator.sunriseSunset(latitude: lat, longitude: lon, date: now),
           now < sun.sunrise || now > sun.sunset { return false }
        guard let forecasts = MarineWeatherService.shared.cachedForecast(latitude: lat, longitude: lon),
              let f = forecasts.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) })
        else { return false }
        let surf = (setup.surfConditions ?? SurfConditions()).adjusted(for: setup.riderLevel)
        return surf.isSatisfied(at: f, tideState: nil)
    }

    private func fireSurfGo(setup: SportSetup, spot: String, lat: Double, lon: Double, now: Date) async {
        guard PremiumManager.shared.isPremium else { return }
        var detail = ""
        if let forecasts = MarineWeatherService.shared.cachedForecast(latitude: lat, longitude: lon),
           let f = forecasts.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }),
           let h = f.swellHeight ?? f.waveHeight {
            let p = Int((f.swellPeriod ?? f.wavePeriod ?? 0).rounded())
            detail = String(format: "%.1f m", h) + (p > 0 ? " · \(p) s" : "")
        }
        await NotificationDispatcher.shared.send(
            title: String(localized: "Fenêtre de GO — \(setup.sport.localizedName)"),
            body: detail.isEmpty
                ? String(localized: "Conditions de surf réunies à \(spot) (prévision).")
                : String(localized: "\(detail) à \(spot) — c'est le moment de surfer (prévision).")
        )
        appLogger.info("[GoWindow] surf GO à \(spot) : \(detail)")
    }
}
