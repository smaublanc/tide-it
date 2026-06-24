//
//  WidgetDataWriter.swift
//  Tide It
//
//  Écrit les données de marée dans le conteneur partagé pour le widget
//

import Foundation
import WidgetKit

enum WidgetDataWriter {
    
    static func saveForWidget(
        portName: String,
        portId: String? = nil,
        tideData: [TideData],
        currentTime: Date = Date(),
        portTimeZoneIdentifier: String = "Europe/Paris",
        latitude: Double? = nil,
        longitude: Double? = nil,
        observedWind: ObservedWindSnapshot? = nil,
        forecastWind: ForecastWindSnapshot? = nil,
        isSurfSpot: Bool = false,
        surf: SurfSnapshot? = nil
    ) {
        guard WidgetSharedKeys.sharedDefaults != nil else { return }

        // tideData déjà trié par TideService
        let sorted = tideData

        // Construire le tableau complet pour résolution autonome widget/watch
        let allTides = sorted.map {
            SimpleTide(date: $0.date, height: $0.height, isHigh: $0.isHighTide, coefficient: $0.coefficient)
        }

        // Système d'unités courant (pour la Watch, qui n'a pas accès aux réglages iPhone).
        let measureSystemRaw = WidgetSharedKeys.sharedDefaults?.string(forKey: "measureSystem")
        let windSpeedUnitRaw = WidgetSharedKeys.sharedDefaults?.string(forKey: "windSpeedUnit")

        // Vent verrouillé (non-premium) : NE PAS écrire de valeur — sinon les surfaces qui
        // ne lisent pas `realtimeWindLocked` (copies Watch) affichent un « 0 km/h N »
        // fantôme. On garde station/distance + le flag verrou pour l'upsell.
        let lockedWind = (observedWind?.premiumLocked == true)
        let effObservedWindKmh = lockedWind ? nil : observedWind?.speedKmh
        let effObservedWindGustKmh = lockedWind ? nil : observedWind?.gustKmh
        let effObservedWindDirDeg = lockedWind ? nil : observedWind?.directionDeg

        // Lever / coucher du soleil du jour au port (calcul astronomique local, sans réseau).
        var sunrise: Date?
        var sunset: Date?
        if let lat = latitude, let lon = longitude,
           let sun = SolarCalculator.sunriseSunset(latitude: lat, longitude: lon, date: currentTime) {
            sunrise = sun.sunrise
            sunset = sun.sunset
        }

        guard let state = TideCalculator.currentState(at: currentTime, sortedTides: sorted),
              let nextTide = state.nextTide else {
            let data = WidgetSharedData(
                portName: portName,
                nextTideDate: currentTime,
                nextTideHeight: 0,
                nextTideIsHigh: false,
                nextTideCoef: nil,
                currentHeight: 0,
                trend: "—",
                updatedAt: currentTime,
                allTides: allTides,
                timeZoneIdentifier: portTimeZoneIdentifier,
                measureSystemRaw: measureSystemRaw,
                windSpeedUnitRaw: windSpeedUnitRaw,
                sunrise: sunrise,
                sunset: sunset,
                observedWindKmh: effObservedWindKmh,
                observedWindGustKmh: effObservedWindGustKmh,
                observedWindDirDeg: effObservedWindDirDeg,
                observedWindStation: observedWind?.stationName,
                observedWindDistanceKm: observedWind?.distanceKm,
                observedWindDate: observedWind?.date,
                realtimeWindLocked: observedWind?.premiumLocked,
                forecastWindKmh: forecastWind?.speedKmh,
                forecastWindGustKmh: forecastWind?.gustKmh,
                forecastWindDirDeg: forecastWind?.directionDeg,
                forecastWindConfidence: forecastWind?.confidence,
                portId: portId,
                latitude: latitude,
                longitude: longitude,
                isSurfSpot: isSurfSpot,
                surfSwellHeightM: surf?.swellHeightM,
                surfSwellPeriodS: surf?.swellPeriodS,
                surfSwellDirectionDeg: surf?.swellDirectionDeg,
                surfGradeRaw: surf?.gradeRaw
            )
            save(data, portId: portId)
            return
        }

        // 2ème marée : celle après la prochaine
        let secondTide = sorted.first { $0.date > nextTide.date }

        // Coefficient du jour : chercher dans toutes les marées du jour (PM uniquement ont un coef)
        let portTimeZone = TimeZone(identifier: portTimeZoneIdentifier) ?? .current
        let calendar = Calendar.inTimeZone(portTimeZone)
        let todayCoef = sorted
            .filter { calendar.isDate($0.date, inSameDayAs: currentTime) }
            .compactMap(\.coefficient)
            .first

        let data = WidgetSharedData(
            portName: portName,
            nextTideDate: nextTide.date,
            nextTideHeight: nextTide.height,
            nextTideIsHigh: nextTide.isHighTide,
            nextTideCoef: nextTide.coefficient,
            currentHeight: state.currentHeight,
            trend: state.trend.description,
            updatedAt: currentTime,
            todayCoef: todayCoef,
            previousTideDate: state.previousTide?.date,
            previousTideHeight: state.previousTide?.height,
            secondTideDate: secondTide?.date,
            secondTideHeight: secondTide?.height,
            secondTideIsHigh: secondTide?.isHighTide,
            secondTideCoef: secondTide?.coefficient,
            allTides: allTides,
            timeZoneIdentifier: portTimeZoneIdentifier,
            measureSystemRaw: measureSystemRaw,
            windSpeedUnitRaw: windSpeedUnitRaw,
            sunrise: sunrise,
            sunset: sunset,
            observedWindKmh: effObservedWindKmh,
            observedWindGustKmh: effObservedWindGustKmh,
            observedWindDirDeg: effObservedWindDirDeg,
            observedWindStation: observedWind?.stationName,
            observedWindDistanceKm: observedWind?.distanceKm,
            observedWindDate: observedWind?.date,
            realtimeWindLocked: observedWind?.premiumLocked,
            forecastWindKmh: forecastWind?.speedKmh,
            forecastWindGustKmh: forecastWind?.gustKmh,
            forecastWindDirDeg: forecastWind?.directionDeg,
            forecastWindConfidence: forecastWind?.confidence,
            portId: portId,
            latitude: latitude,
            longitude: longitude,
            isSurfSpot: isSurfSpot,
            surfSwellHeightM: surf?.swellHeightM,
            surfSwellPeriodS: surf?.swellPeriodS,
            surfSwellDirectionDeg: surf?.swellDirectionDeg,
            surfGradeRaw: surf?.gradeRaw
        )
        save(data, portId: portId)
    }

    /// Instantané de vent observé passé par l'app (calculé sur le MainActor).
    struct ObservedWindSnapshot {
        let speedKmh: Double
        let gustKmh: Double?
        let directionDeg: Double
        let stationName: String
        let distanceKm: Double
        let date: Date
        /// true = balise présente mais vent temps réel réservé au premium → upsell widget.
        let premiumLocked: Bool
    }

    /// Instantané de vent PRÉVU (Open-Meteo) — repli du widget quand pas de balise.
    struct ForecastWindSnapshot {
        let speedKmh: Double
        let gustKmh: Double?
        let directionDeg: Double
        let confidence: Double?
    }

    /// Instantané SURF (spot de surf uniquement) : houle dominante + verdict, calculé sur le
    /// MainActor depuis le cache marine. Provenance modèle large — jamais spot-grade.
    struct SurfSnapshot {
        let swellHeightM: Double
        let swellPeriodS: Double
        let swellDirectionDeg: Double?
        let gradeRaw: String
    }

    /// Signature du planning de marées (port + valeurs des marées). Change UNIQUEMENT
    /// quand le planning lui-même change — pas quand seuls `currentHeight`/`updatedAt`
    /// évoluent (ces valeurs sont recalculées en autonomie par le widget/la watch via
    /// `allTides`). Permet de ne recharger widgets + watch que sur vrai changement.
    private static var lastScheduleSignature: Int?
    private static var lastWindSignature: Int?
    private static var lastSurfSignature: Int?

    /// Signature du vent observé : change quand la mesure, la balise ou l'état premium évoluent.
    private static func windSignature(_ data: WidgetSharedData) -> Int {
        var hasher = Hasher()
        // Le PORT fait partie de la signature : le widget Vent affiche aussi la MARÉE (pied de
        // widget). Sans ça, un changement de port qui ne change pas la balise (même station) ne
        // rechargeait pas le widget → sa marée restait figée sur l'ancien port.
        hasher.combine(data.portName)
        hasher.combine(data.observedWindStation ?? "")
        hasher.combine(Int((data.observedWindKmh ?? -1).rounded()))
        hasher.combine(Int((data.observedWindDirDeg ?? -1).rounded()))
        hasher.combine(data.realtimeWindLocked ?? false)
        return hasher.finalize()
    }

    /// Signature SURF : change quand la houle/le verdict évoluent OU quand on change de port (le
    /// widget surf affiche aussi la marée du spot → il doit suivre le port actif, pas seulement la houle).
    private static func surfSignature(_ data: WidgetSharedData) -> Int {
        var hasher = Hasher()
        hasher.combine(data.portName)
        hasher.combine(data.isSurfSpot ?? false)
        hasher.combine(Int(((data.surfSwellHeightM ?? -1) * 10).rounded()))
        hasher.combine(Int((data.surfSwellPeriodS ?? -1).rounded()))
        hasher.combine(Int((data.surfSwellDirectionDeg ?? -1).rounded()))
        hasher.combine(data.surfGradeRaw ?? "")
        return hasher.finalize()
    }

    private static func scheduleSignature(_ data: WidgetSharedData) -> Int {
        var hasher = Hasher()
        hasher.combine(data.portName)
        for t in data.allTides {
            hasher.combine(Int(t.date.timeIntervalSince1970))
            hasher.combine(Int((t.height * 100).rounded()))
            hasher.combine(t.coefficient ?? -1)
        }
        return hasher.finalize()
    }

    /// Supprime les données widget d'un port supprimé : la clé par-port + son entrée dans le
    /// registre des ports disponibles (sinon il resterait sélectionnable dans le widget configurable).
    static func removePort(portId: String) {
        guard let defaults = WidgetSharedKeys.sharedDefaults else { return }
        defaults.removeObject(forKey: WidgetSharedKeys.portDataKey(portId))
        if var available = defaults.dictionary(forKey: WidgetSharedKeys.availablePortsKey) as? [String: String],
           available.removeValue(forKey: portId) != nil {
            defaults.set(available, forKey: WidgetSharedKeys.availablePortsKey)
        }
        // Widget surf « collant » : si le DERNIER spot surf mémorisé est CE port, on l'oublie
        // (sinon le widget surf resterait bloqué sur un spot supprimé).
        if let blob = defaults.data(forKey: WidgetSharedKeys.lastSurfDataKey),
           let decoded = try? JSONDecoder().decode(WidgetSharedData.self, from: blob),
           decoded.portId == portId {
            defaults.removeObject(forKey: WidgetSharedKeys.lastSurfDataKey)
        }
    }

    private static func save(_ data: WidgetSharedData, portId: String? = nil) {
        guard let defaults = WidgetSharedKeys.sharedDefaults else { return }
        guard let encoded = try? JSONEncoder().encode(data) else { return }

        // Toujours écrire les données fraîches (snapshots immédiats restent à jour)
        defaults.set(encoded, forKey: WidgetSharedKeys.dataKey)
        // Si c'est un SPOT DE SURF avec de la houle, on mémorise ce snapshot à part : le widget surf
        // restera « collant » sur ce spot même quand l'app affiche ensuite un port classique.
        if data.isSurfSpot == true, data.surfSwellHeightM != nil {
            defaults.set(encoded, forKey: WidgetSharedKeys.lastSurfDataKey)
        }
        if let portId {
            defaults.set(encoded, forKey: WidgetSharedKeys.portDataKey(portId))
            var available = defaults.dictionary(forKey: WidgetSharedKeys.availablePortsKey) as? [String: String] ?? [:]
            available[portId] = data.portName
            defaults.set(available, forKey: WidgetSharedKeys.availablePortsKey)
        }

        // Widget Vent : rechargé quand la MESURE de vent change (indépendant du planning
        // de marée). WidgetKit borne de toute façon la fréquence réelle des reloads.
        let windSig = windSignature(data)
        let scheduleSig = scheduleSignature(data)
        let surfSig = surfSignature(data)
        let windChanged = windSig != lastWindSignature
        let scheduleChanged = scheduleSig != lastScheduleSignature
        let surfChanged = surfSig != lastSurfSignature

        if windChanged {
            lastWindSignature = windSig
            WidgetCenter.shared.reloadTimelines(ofKind: "TideWindWidget")
        }

        // Widget surf : rechargé quand la houle/le verdict changent (spot de surf uniquement).
        if surfChanged {
            lastSurfSignature = surfSig
            WidgetCenter.shared.reloadTimelines(ofKind: "SurfWidget")
        }

        // Widgets marée : rechargés uniquement si le planning a réellement changé.
        if scheduleChanged {
            lastScheduleSignature = scheduleSig
            WidgetCenter.shared.reloadTimelines(ofKind: "TideItWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "TideItConfigurableWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "TideLockScreenWidget")
        }

        // Watch : envoyer dès que le planning OU le VENT change. (Bug historique : le vent
        // évolue indépendamment du planning → la Watch ne le recevait jamais.) Le
        // throttle 60 s de WatchSessionManager évite tout spam.
        if scheduleChanged || windChanged {
            // Favoris pour le carrousel Watch : réutilise les blobs par-port DÉJÀ en cache (aucun
            // recalcul), encodés À PART. `data` (la marée) part inchangé → décodage Watch jamais cassé.
            let favData = watchFavoritesData(excluding: portId, from: defaults)
            // WatchSessionManager est @MainActor (anti-course) ; `save` est nonisolated → saut explicite.
            Task { @MainActor in WatchSessionManager.shared.sendTideData(data, favoritesData: favData) }
        }
    }

    /// Favoris du carrousel Watch encodés (`[WidgetSharedData]` → Data), construits SANS recalcul
    /// à partir des blobs par-port déjà écrits dans l'App Group. nil si aucun favori en cache. Borné à 6.
    private static func watchFavoritesData(excluding currentPortId: String?, from defaults: UserDefaults) -> Data? {
        let favIDs = UserDefaults.standard.stringArray(forKey: "favoritePorts") ?? []
        guard !favIDs.isEmpty else { return nil }
        var out: [WidgetSharedData] = []
        for id in favIDs where id != currentPortId {
            guard out.count < 6 else { break }
            if let blob = defaults.data(forKey: WidgetSharedKeys.portDataKey(id)),
               let decoded = try? JSONDecoder().decode(WidgetSharedData.self, from: blob) {
                out.append(decoded)
            }
        }
        return out.isEmpty ? nil : (try? JSONEncoder().encode(out))
    }
}

// MARK: - Calcul solaire (lever / coucher du soleil, hors-ligne)

/// Calcule lever et coucher du soleil à partir de coordonnées et d'une date, sans
/// réseau ni WeatherKit (algorithme « Sunrise/Sunset » de l'Almanac for Computers).
/// Renvoie des instants absolus (UTC) → à formater dans le fuseau du port.
enum SolarCalculator {
    /// - Returns: (sunrise, sunset) en absolu, ou `nil` aux latitudes en jour/nuit polaire.
    static func sunriseSunset(latitude: Double, longitude: Double, date: Date) -> (sunrise: Date, sunset: Date)? {
        let zenith = 90.833            // zénith officiel (réfraction + rayon solaire)
        let rad = Double.pi / 180, deg = 180 / Double.pi

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) else { return nil }
        let comps = cal.dateComponents([.year, .month, .day], from: date)

        func event(rising: Bool) -> Date? {
            let lngHour = longitude / 15.0
            let t = Double(dayOfYear) + ((rising ? 6.0 : 18.0) - lngHour) / 24.0

            let M = (0.9856 * t) - 3.289                                   // anomalie moyenne
            var L = M + (1.916 * sin(M * rad)) + (0.020 * sin(2 * M * rad)) + 282.634
            L = (L.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)

            var RA = deg * atan(0.91764 * tan(L * rad))                    // ascension droite
            RA = (RA.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            RA += (floor(L / 90) * 90) - (floor(RA / 90) * 90)             // même quadrant que L
            RA /= 15.0

            let sinDec = 0.39782 * sin(L * rad)
            let cosDec = cos(asin(sinDec))
            let cosH = (cos(zenith * rad) - (sinDec * sin(latitude * rad))) / (cosDec * cos(latitude * rad))
            if cosH > 1 || cosH < -1 { return nil }                        // jour/nuit polaire

            var H = rising ? (360 - deg * acos(cosH)) : (deg * acos(cosH))
            H /= 15.0
            let localT = H + RA - (0.06571 * t) - 6.622
            // UT de l'événement, normalisé en HEURE DU JOUR [0,24).
            let utHours = ((localT - lngHour).truncatingRemainder(dividingBy: 24) + 24)
                .truncatingRemainder(dividingBy: 24)

            var c = comps
            c.timeZone = TimeZone(identifier: "UTC")
            c.hour = 0; c.minute = 0; c.second = 0
            guard let midnightUTC = cal.date(from: c) else { return nil }
            let candidate = midnightUTC.addingTimeInterval(utHours * 3600.0)

            // ⚠️ Reporter le bon JOUR UTC : pour un port loin de Greenwich, l'événement du
            // jour LOCAL tombe sur la veille/lendemain UTC (Los Angeles : coucher ~02:00 UTC
            // le lendemain). On choisit le décalage de ±24 h qui rapproche le plus du MIDI
            // LOCAL du jour demandé. L'ancien code figeait tout sur le même jour UTC →
            // coucher 24 h trop tôt → « Sorties Parfaites » cassées sur le Pacifique/l'Asie.
            let localNoonUTC = midnightUTC.addingTimeInterval((12.0 - lngHour) * 3600.0)
            var best = candidate
            for shift in [-86400.0, 86400.0] {
                let alt = candidate.addingTimeInterval(shift)
                if abs(alt.timeIntervalSince(localNoonUTC)) < abs(best.timeIntervalSince(localNoonUTC)) {
                    best = alt
                }
            }
            return best
        }

        guard let sunrise = event(rising: true), let sunset = event(rising: false) else { return nil }
        return (sunrise, sunset)
    }
}
