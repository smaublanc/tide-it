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
        // ⚠️ LA GARDE `hasActiveAlert()` A ÉTÉ DESCENDUE, et c'est le correctif des « coupures ».
        //
        // Elle était en tête : sans alerte « le vent s'établit », cette fonction sortait
        // immédiatement — donc AUCUNE balise lue et AUCUN échantillon écrit, alors que le réveil
        // de fond avait bien eu lieu (toutes les 30 min demandées, cadence réelle décidée par
        // iOS). La trace du réel ne se remplissait qu'aux heures où l'app était OUVERTE, d'où des
        // îlots séparés par des heures de vide sur la courbe.
        //
        // La lecture de balise est donc désormais INCONDITIONNELLE pour le port suivi ; seule la
        // machine à états des alertes reste derrière la garde, en bas. Un port, une petite requête
        // par réveil, vers les balises tierces et non vers la prévision — c'est le prix minimal
        // d'une trace continue, et c'est le même que payait déjà le chemin des alertes.
        guard let p = UserDefaults.standard.dictionary(forKey: portKey),
              let id = p["id"] as? String, let name = p["name"] as? String,
              let lat = p["lat"] as? Double, let lon = p["lon"] as? Double else { return }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        await WindStationAggregator.shared.refresh(around: coord, force: true)
        let station = WindStationAggregator.shared.nearestStationWithDistance(to: coord)
        let reading = station?.station.reading
        // TRACE DU RÉEL — la mesure qu'on vient de télécharger est enregistrée au passage.
        //
        // Pas de `modelKmh` ici, et c'est délibéré : aller chercher la prévision coûterait un
        // second appel réseau. L'échantillon nourrit donc la trace, pas la jauge de biais
        // (cf. `ForecastBiasService.Sample.model`, optionnel exactement pour ce cas).
        if let r = reading, let s = station {
            ForecastBiasService.shared.record(
                portId: id, modelKmh: nil, observedKmh: r.speedAvgKmh,
                distanceKm: s.distance / 1000, at: r.date,
                gustKmh: r.gustKmh, stationID: s.station.id)
        }
        // Machine à états des alertes : elle, reste conditionnée à une alerte active.
        guard Self.hasActiveAlert() else { return }
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

    // MARK: - Repérage anticipé d'une fenêtre GO (« on revient vers toi si ça se confirme »)

    /// État du repérage anticipé, par `portId|sport|jour` → étape (`spotted` puis `closed`).
    /// `closed` = le retour promis (confirmation OU annulation) a été envoyé : on n'y revient plus.
    private let goAheadKey = "goWindow.aheadState"
    /// Dernier scan prévisionnel (un par jour, cf. `goAheadScanInterval`).
    private let goAheadScanKey = "goWindow.aheadLastScan"

    /// UN scan par jour : ce repérage demande une prévision par spot abonné. À la cadence de
    /// réveil d'iOS (30 min) ce serait absurde pour la batterie ET pour le quota de l'API.
    private let goAheadScanInterval: TimeInterval = 20 * 3600
    /// Horizon du repérage : au-delà de J+5 les modèles ne valent rien pour du vent local ;
    /// en deçà de J+2 il n'y a plus rien à planifier (les autres notifs couvrent le court terme).
    private let goAheadMinDays = 2
    private let goAheadMaxDays = 5
    /// Une fenêtre trop courte n'est pas une sortie : on ne dérange pas pour 1 h.
    private let goAheadMinHours: Double = 2
    /// Accord inter-modèles minimal (AROME/ICON/GFS) pour ANNONCER une fenêtre. C'est le cœur
    /// de la promesse : on ne signale que ce qui a de vraies chances de se réaliser. Sans mesure
    /// de confiance sur la fenêtre, on se tait — on n'annonce jamais à l'aveugle.
    private let goAheadMinConfidence: Double = 0.6

    /// INTERRUPTEUR DE LIVRAISON — `true` depuis la 5.3 (était `false` en 5.2.9).
    ///
    /// Cette notification fait une PROMESSE (« on revient vers toi la veille ») et c'est iOS
    /// qui décide de ses réveils d'arrière-plan : si celui de la veille ne vient pas, quelqu'un
    /// pose sa journée pour rien. Avant de soumettre à l'App Store, deux choses doivent être
    /// vraies : le terrain a confirmé qu'iOS réveille bien l'app (cf. `debugForceGoAheadScan`),
    /// et le calendrier porte l'état « repérée / confirmée » — le filet qui rattrape un réveil
    /// manqué. Repasser à `false` suffit à tout éteindre sans rien démonter.
    private let goAheadShipped = true

    private var goAhead: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: goAheadKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: goAheadKey) }
    }

    /// Purge SYNCHRONE de tout l'état par-spot/par-alerte d'un port supprimé. Les notifs GO et
    /// « vent s'établit » partent via un identifiant UUID aléatoire + trigger 1 s → NON annulables
    /// après coup ; tuer l'état qui les régénère en arrière-plan est le seul correctif durable.
    func purge(portId: String, alertIds: [String] = []) {
        let prefix = "\(portId)|"
        goPending = goPending.filter { !$0.key.hasPrefix(prefix) }
        goFired   = goFired.filter   { !$0.key.hasPrefix(prefix) }
        goAhead   = goAhead.filter   { !$0.key.hasPrefix(prefix) }   // repérages anticipés du spot
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
                    await fireSurfGo(setup: setup, spot: portName, portId: portId, lat: lat, lon: lon, now: now)
                    fired[key] = now.timeIntervalSince1970
                }
                pend[key] = nil
                continue
            }

            // JOUR seulement, comme le surf (`surfGoNow`) : une fenêtre GO vent ne se navigue pas
            // dans le noir. Sans ce gate, la machine à états pouvait confirmer et notifier en
            // pleine nuit — se faire réveiller à 3 h fait désinstaller une app. Coordonnées
            // absentes (chemin legacy) → pas de gate, on ne bloque pas sur une position inconnue.
            if !isDaylight(lat: lat, lon: lon, now: now) { pend[key] = nil; continue }

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
                        await fireGo(sport: setup.sport, spot: portName, portId: portId, speed: r.speedAvgKmh)
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

    private func fireGo(sport: WindSport, spot: String, portId: String, speed: Double) async {
        guard PremiumManager.shared.isPremium else { return }
        let unit = WindSpeedUnit(rawValue: UserDefaults.standard.string(forKey: "windSpeedUnit") ?? "") ?? .kmh
        await NotificationDispatcher.shared.send(
            title: String(localized: "Fenêtre de GO — \(sport.localizedName)"),
            body: String(localized: "\(UnitFormatter.windSpeed(speed, unit: unit)) établi à \(spot) (balise). C'est le moment."),
            // La fenêtre est MAINTENANT : bornes ouvertes sur l'heure qui vient, de quoi
            // surligner le créneau à l'ouverture.
            target: NotificationTarget(portId: portId, portName: spot, sport: sport.rawValue,
                                       start: Date(), end: Date().addingTimeInterval(3600))
        )
        appLogger.info("[GoWindow] \(sport.rawValue) GO confirmé à \(spot) : \(Int(speed)) km/h")
    }

    /// Fait-il jour au spot ? SOURCE UNIQUE du garde-fou nocturne, partagée par le vent et le surf
    /// (le vent n'en avait pas : ses notifs pouvaient tomber en pleine nuit). Position inconnue →
    /// `true` : on ne bloque jamais une notif sur une donnée qu'on n'a pas.
    private func isDaylight(lat: Double?, lon: Double?, now: Date) -> Bool {
        guard let lat, let lon,
              let sun = SolarCalculator.sunriseSunset(latitude: lat, longitude: lon, date: now)
        else { return true }
        return now >= sun.sunrise && now <= sun.sunset
    }

    /// La fenêtre SURF est-elle ouverte MAINTENANT ? Évalue les SurfConditions (ajustées au niveau)
    /// sur l'heure de prévision marine en cache la plus proche de `now`, de JOUR uniquement.
    /// Pas de marée en arrière-plan → le gate marée optionnel est ignoré (jamais de faux négatif).
    private func surfGoNow(setup: SportSetup, lat: Double, lon: Double, now: Date) -> Bool {
        // Jour seulement : pas de notif surf en pleine nuit.
        if !isDaylight(lat: lat, lon: lon, now: now) { return false }
        guard let forecasts = MarineWeatherService.shared.cachedForecast(latitude: lat, longitude: lon),
              let f = forecasts.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) })
        else { return false }
        let surf = (setup.surfConditions ?? SurfConditions()).adjusted(for: setup.riderLevel)
        return surf.isSatisfied(at: f, tideState: nil)
    }

    private func fireSurfGo(setup: SportSetup, spot: String, portId: String, lat: Double, lon: Double, now: Date) async {
        guard PremiumManager.shared.isPremium else { return }
        var detail = ""
        if let forecasts = MarineWeatherService.shared.cachedForecast(latitude: lat, longitude: lon),
           let f = forecasts.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }),
           let h = f.swellHeight ?? f.waveHeight {
            let p = Int((f.swellPeriod ?? f.wavePeriod ?? 0).rounded())
            detail = String(format: "%.1f m", locale: Locale.current, h) + (p > 0 ? " · \(p) s" : "")
        }
        await NotificationDispatcher.shared.send(
            title: String(localized: "Fenêtre de GO — \(setup.sport.localizedName)"),
            body: detail.isEmpty
                ? String(localized: "Conditions de surf réunies à \(spot) (prévision).")
                : String(localized: "\(detail) à \(spot) — c'est le moment de surfer (prévision)."),
            target: NotificationTarget(portId: portId, portName: spot, sport: setup.sport.rawValue,
                                       start: now, end: now.addingTimeInterval(3600))
        )
        appLogger.info("[GoWindow] surf GO à \(spot) : \(detail)")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Repérage anticipé : « une fenêtre se dessine, on revient vers toi »
    //
    // Troisième machine à états, à côté de « le vent s'établit » et « fenêtre GO maintenant ».
    // Celle-ci regarde LOIN (J+2 à J+5) et annonce UNE fenêtre : la PLUS FIABLE, pas la
    // première venue. Puis elle tient sa promesse — la veille, elle revient dire si ça se
    // confirme OU si ça ne tient plus. Sans ce retour, l'annonce serait un mensonge par
    // omission : quelqu'un pose sa journée et se retrouve sans vent.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Une fenêtre candidate + sa fiabilité, pour pouvoir CHOISIR la meilleure.
    private struct AheadCandidate {
        let sport: WindSport
        let day: Date
        let window: GoWindow
        let confidence: Double   // accord inter-modèles moyen sur les heures de la fenêtre
        let hours: Double
        /// On préfère une fenêtre SÛRE à une fenêtre longue — mais SEULEMENT là où la confiance
        /// veut encore dire quelque chose.
        ///
        /// Mesuré sur 2 800 heures de vent observé (17 stations côtières, août 2026), l'erreur
        /// réelle du modèle par tranche de confiance :
        ///     0,20–0,50 → 3,48 km/h     0,70–0,85 → 2,17
        ///     0,50–0,70 → 2,53          0,85–1,00 → 2,27 puis 2,34
        /// L'accord entre modèles discrimine donc FORT jusqu'à ~0,75, puis PLUS DU TOUT : au-delà,
        /// l'erreur ne baisse plus, elle remonte même légèrement. Départager 0,88 de 0,96 revenait
        /// à trancher sur du bruit — et à écarter des fenêtres plus longues pour rien.
        /// On sature donc la confiance à 0,75 dans le classement ; au-dessus, c'est la durée
        /// qui décide.
        static let confidenceCeiling = 0.75
        var rank: Double { min(confidence, Self.confidenceCeiling) * 100 + min(hours, 4) }
    }

    /// Scan quotidien du planning d'activité, en arrière-plan. Premium + spots abonnés seulement.
    func evaluateGoAheadInBackground(now: Date = Date()) async {
        guard goAheadShipped else { return }   // cf. goAheadShipped
        await runGoAheadScan(now: now)
    }

    #if DEBUG
    /// Test sur appareil. Sans ça, vérifier ce repérage demanderait d'attendre le lendemain ET
    /// qu'iOS veuille bien réveiller l'app : le compteur de scan et l'état déjà notifié sont
    /// remis à zéro, et l'interrupteur de livraison est contourné.
    ///
    /// `daysFromNow` décale la date du scan : c'est le SEUL moyen d'atteindre la seconde moitié
    /// de la fonctionnalité — la promesse tenue. Repérer aujourd'hui une fenêtre à J+3, puis
    /// relancer à J+2, place cette fenêtre à « demain » et déclenche la confirmation (ou
    /// l'annulation). Sans ce décalage il faudrait attendre trois jours pour savoir si la moitié
    /// qui engage l'app fonctionne.
    func debugForceGoAheadScan(daysFromNow: Int = 0) async {
        UserDefaults.standard.removeObject(forKey: goAheadScanKey)
        if daysFromNow == 0 { goAhead = [:] }   // un décalage rejoue l'état, il ne l'efface pas
        let now = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Date()) ?? Date()
        await runGoAheadScan(now: now)
    }
    #endif

    private func runGoAheadScan(now: Date) async {
        guard PremiumManager.shared.isPremium else { return }
        // UN scan par jour (cf. goAheadScanInterval) : une prévision par spot, ce n'est pas
        // une opération à répéter toutes les 30 min.
        let last = UserDefaults.standard.double(forKey: goAheadScanKey)
        guard last == 0 || now.timeIntervalSince1970 - last >= goAheadScanInterval else { return }

        let coordsMap = (UserDefaults.standard.dictionary(forKey: goCoordsKey) as? [String: [String: Any]]) ?? [:]
        let spots = SportSetupStore.shared.notifyEnabledPortIDs
        guard !spots.isEmpty, !coordsMap.isEmpty else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: goAheadScanKey)

        for portId in spots {
            guard let meta = coordsMap[portId],
                  let name = meta["name"] as? String,
                  let lat = meta["lat"] as? Double, let lon = meta["lon"] as? Double else { continue }
            await scanSpotAhead(portId: portId, name: name, lat: lat, lon: lon, now: now)
        }
    }

    private func scanSpotAhead(portId: String, name: String, lat: Double, lon: Double, now: Date) async {
        let setups = SportSetupStore.shared.enabledSetups(for: portId)
        guard !setups.isEmpty else { return }

        let forecasts = await MarineWeatherService.shared.fetchHourlyForecast(latitude: lat, longitude: lon)
        guard !forecasts.isEmpty else { return }

        // Marées : LOCALES (cache, sinon calcul harmonique) — aucun réseau supplémentaire.
        let tides = TideCache.shared.getEvenIfExpired(portId: portId)
            ?? TideRepository.shared.fetchFromHarmonics(portId: portId)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: (UserDefaults.standard.dictionary(forKey: goCoordsKey)?[portId] as? [String: Any])?["tz"] as? String ?? "") ?? .current
        let startDay = cal.startOfDay(for: now)

        var sun: [(sunrise: Date, sunset: Date)] = []
        for d in 0...(goAheadMaxDays + 1) {
            if let day = cal.date(byAdding: .day, value: d, to: startDay),
               let s = SolarCalculator.sunriseSunset(latitude: lat, longitude: lon, date: day) {
                sun.append(s)
            }
        }

        // MÊME moteur que le calendrier de l'app (scorer AUTO inclus) → jamais de contradiction
        // entre ce qu'annonce la notification et ce que montre l'écran Activités.
        let spotCfg = SpotConfigStore.shared.config(for: portId)
        let plan = await MainActor.run {
            ActivityGoPlanner.plan(
                setups: setups, forecasts: forecasts, sunTimes: sun, tideData: tides,
                from: now, days: goAheadMaxDays + 1, calendar: cal,
                scorer: { sport, f, lvl in
                    ActivityScoreService.shared.scoreHour(sport: sport, at: f, tideData: tides,
                                                          spot: spotCfg, riderLevel: lvl)
                }
            )
        }

        var state = goAhead
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.timeZone = cal.timeZone

        // ── 1. La promesse tenue : pour tout repérage dont le jour est DEMAIN, on revient. ──
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: startDay) {
            let tomorrowKey = dayFmt.string(from: tomorrow)
            for (key, stage) in state where stage == "spotted" && key.hasSuffix("|\(tomorrowKey)") {
                let parts = key.split(separator: "|")
                guard parts.count == 3, parts[0] == portId,
                      let sport = WindSport(rawValue: String(parts[1])) else { continue }
                let stillThere = plan.first { cal.isDate($0.day, inSameDayAs: tomorrow) }?
                    .lanes.first { $0.sport == sport }?
                    .windows.first { $0.end.timeIntervalSince($0.start) >= goAheadMinHours * 3600 }
                await fireAheadFollowUp(sport: sport, spot: name, portId: portId, window: stillThere,
                                        timeZone: cal.timeZone, lat: lat, lon: lon, now: now)
                state[key] = "closed"
            }
        }

        // ── 2. Le repérage : on retient LA fenêtre la plus fiable de l'horizon. ──
        var best: AheadCandidate?
        for offset in goAheadMinDays...goAheadMaxDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: startDay),
                  let dayPlan = plan.first(where: { cal.isDate($0.day, inSameDayAs: day) }) else { continue }
            for lane in dayPlan.lanes {
                for w in lane.windows {
                    let hours = w.end.timeIntervalSince(w.start) / 3600
                    guard hours >= goAheadMinHours else { continue }
                    // Confiance = accord inter-modèles MOYEN sur les heures de la fenêtre.
                    // Aucune heure mesurée → on ne peut rien promettre : la fenêtre est écartée.
                    let confs = forecasts
                        .filter { $0.time >= w.start && $0.time < w.end }
                        .compactMap(\.windConfidence)
                    guard !confs.isEmpty else { continue }
                    let conf = confs.reduce(0, +) / Double(confs.count)
                    guard conf >= goAheadMinConfidence else { continue }
                    let c = AheadCandidate(sport: lane.sport, day: day, window: w, confidence: conf, hours: hours)
                    if best == nil || c.rank > best!.rank { best = c }
                }
            }
        }

        if let c = best {
            let key = "\(portId)|\(c.sport.rawValue)|\(dayFmt.string(from: c.day))"
            if state[key] == nil {   // jamais deux annonces pour le même spot+sport+jour
                await fireAheadSpotted(sport: c.sport, spot: name, portId: portId, day: c.day,
                                       window: c.window, timeZone: cal.timeZone, now: now,
                                       lat: lat, lon: lon)
                state[key] = "spotted"
            }
        }

        // Purge des clés dont le jour est passé (borne la croissance du dictionnaire).
        let todayKey = dayFmt.string(from: startDay)
        state = state.filter { key, _ in
            guard let dayPart = key.split(separator: "|").last else { return false }
            return String(dayPart) >= todayKey
        }
        goAhead = state
    }

    /// « Une fenêtre se dessine » — annonce PRUDENTE : elle dit son incertitude et promet le retour.
    private func fireAheadSpotted(sport: WindSport, spot: String, portId: String, day: Date,
                                  window: GoWindow, timeZone: TimeZone, now: Date,
                                  lat: Double, lon: Double) async {
        guard PremiumManager.shared.isPremium, isDaylight(lat: lat, lon: lon, now: now) else { return }
        let fmt = DateFormatter(); fmt.locale = .current; fmt.timeZone = timeZone
        fmt.setLocalizedDateFormatFromTemplate("EEEE")
        let dayName = fmt.string(from: day)
        await NotificationDispatcher.shared.send(
            title: String(localized: "Une fenêtre se dessine — \(sport.localizedName)"),
            body: String(localized: "Tide It a repéré un créneau \(dayName) à \(spot). C'est encore une prévision : on revient vers toi la veille pour te dire si ça se confirme."),
            target: NotificationTarget(portId: portId, portName: spot, sport: sport.rawValue,
                                       start: window.start, end: window.end)
        )
        appLogger.info("[GoAhead] repérage \(sport.rawValue) à \(spot) pour \(dayName)")
    }

    /// Le RETOUR promis, dans les deux sens. Une fenêtre qui s'évapore doit être annoncée aussi
    /// clairement qu'une fenêtre qui tient : c'est ce qui sépare une prévision honnête d'un
    /// optimisme publicitaire.
    private func fireAheadFollowUp(sport: WindSport, spot: String, portId: String, window: GoWindow?,
                                   timeZone: TimeZone, lat: Double, lon: Double, now: Date) async {
        guard PremiumManager.shared.isPremium, isDaylight(lat: lat, lon: lon, now: now) else { return }
        let hFmt = DateFormatter(); hFmt.locale = .current; hFmt.timeZone = timeZone
        hFmt.setLocalizedDateFormatFromTemplate("jmm")
        if let w = window {
            let range = "\(hFmt.string(from: w.start))–\(hFmt.string(from: w.end))"
            await NotificationDispatcher.shared.send(
                title: String(localized: "Confirmé — \(sport.localizedName) demain"),
                body: String(localized: "\(spot) : le créneau tient, \(range). Prépare ton matos."),
                target: NotificationTarget(portId: portId, portName: spot, sport: sport.rawValue,
                                           start: w.start, end: w.end)
            )
            appLogger.info("[GoAhead] confirmé \(sport.rawValue) à \(spot) : \(range)")
        } else {
            await NotificationDispatcher.shared.send(
                title: String(localized: "Annulé — \(sport.localizedName) demain"),
                body: String(localized: "\(spot) : le créneau repéré ne tient plus. On te préviendra à la prochaine occasion."),
                // Annulation : on ouvre bien SUR le spot, mais sans fenêtre à surligner —
                // il n'y en a plus. Surligner un créneau annulé serait se contredire.
                target: NotificationTarget(portId: portId, portName: spot)
            )
            appLogger.info("[GoAhead] annulé \(sport.rawValue) à \(spot)")
        }
    }
}
