//
//  Tide_ItTests.swift
//  Tide ItTests
//
//  Tests unitaires sur la LOGIQUE PURE (sans UI ni réseau) :
//  - Résolution des fuseaux horaires des ports SHOM (métropole + outre-mer)
//  - Moteur de marée : interpolation, état courant, règle des douzièmes, stats, coefficient
//  - Données partagées widget : décodage rétrocompatible + fuseau
//  - Helpers de date (Calendar.inTimeZone, formatTideTime)
//

import XCTest
@testable import Tide_It

final class Tide_ItTests: XCTestCase {

    // MARK: - Fuseaux horaires des ports français (Port.frenchTimeZoneIdentifier)

    /// La métropole et chaque DOM-TOM doivent tomber sur le bon fuseau IANA.
    /// Coordonnées tirées du catalogue SHOM réel (shom_ports.txt).
    func testFrenchTimeZoneClassifier() {
        let cases: [(name: String, lat: Double, lon: Double, tz: String)] = [
            ("Brest (métropole)",        48.383,  -4.495,  "Europe/Paris"),
            ("Marseille (métropole)",    43.295,   5.370,  "Europe/Paris"),
            ("Ajaccio (Corse)",          41.918,   8.736,  "Europe/Paris"),
            ("Papeete (Polynésie)",     -17.533, -149.570, "Pacific/Tahiti"),
            ("Vaitape Bora-Bora",       -16.507, -151.753, "Pacific/Tahiti"),
            ("Rikitea (Gambier)",       -23.116, -134.966, "Pacific/Gambier"),
            ("Taiohae (Marquises)",      -8.916, -140.100, "Pacific/Marquesas"),
            ("Nouméa (N.-Calédonie)",   -22.292,  166.435, "Pacific/Noumea"),
            ("Mata-Utu (Wallis)",       -13.285, -176.170, "Pacific/Wallis"),
            ("Saint-Pierre (Réunion)",  -21.345,   55.477, "Indian/Reunion"),
            ("Dzaoudzi (Mayotte)",      -12.781,   45.258, "Indian/Mayotte"),
            ("Port-aux-Français (Kerguelen)", -49.35, 70.216, "Indian/Kerguelen"),
            ("Fort-de-France (Martinique)", 14.601, -61.063, "America/Martinique"),
            ("Pointe-à-Pitre (Guadeloupe)", 16.224, -61.531, "America/Martinique"),
            ("Kourou (Guyane)",           5.156,  -52.626, "America/Cayenne"),
            ("Saint-Pierre-et-Miquelon", 46.785,  -56.167, "America/Miquelon"),
            ("Dumont d'Urville (Adélie)", -66.666, 140.0,  "Antarctica/DumontDUrville"),
        ]
        for c in cases {
            XCTAssertEqual(
                Port.frenchTimeZoneIdentifier(latitude: c.lat, longitude: c.lon),
                c.tz,
                "\(c.name) devrait être \(c.tz)"
            )
        }
    }

    /// Tous les identifiants retournés doivent être des fuseaux IANA valides sur iOS.
    func testFrenchTimeZoneIdentifiersAreValid() {
        let coords: [(Double, Double)] = [
            (48.4, -4.5), (-17.5, -149.6), (-23.1, -135.0), (-8.9, -140.1),
            (-22.3, 166.4), (-13.3, -176.2), (-21.3, 55.5), (-12.8, 45.3),
            (-49.4, 70.2), (14.6, -61.1), (5.2, -52.6), (46.8, -56.2),
            (-66.7, 140.0), (10.3, -109.2), // Clipperton
        ]
        for (lat, lon) in coords {
            let id = Port.frenchTimeZoneIdentifier(latitude: lat, longitude: lon)
            XCTAssertNotNil(TimeZone(identifier: id), "Fuseau invalide: \(id)")
        }
    }

    // MARK: - Moteur de marée (TideCalculator)

    /// Cycle simple : basse mer (1 m) à T, pleine mer (5 m) à T+6h.
    private func makeCycle(base: Date) -> [TideData] {
        [
            TideData(date: base,                              height: 1.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600), height: 5.0, isHighTide: true,  coefficient: 95),
        ]
    }

    func testInterpolatedHeightMidpointIsCosineHalf() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = makeCycle(base: base)
        // À mi-parcours (T+3h), l'interpolation cosinus donne pile la moyenne.
        let mid = TideCalculator.interpolatedHeight(at: base.addingTimeInterval(3 * 3600), sortedTides: tides)
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid!, 3.0, accuracy: 0.0001)
    }

    func testInterpolatedHeightAtEndpoints() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = makeCycle(base: base)
        XCTAssertEqual(TideCalculator.interpolatedHeight(at: base, sortedTides: tides)!, 1.0, accuracy: 0.0001)
        XCTAssertEqual(TideCalculator.interpolatedHeight(at: base.addingTimeInterval(6 * 3600), sortedTides: tides)!, 5.0, accuracy: 0.0001)
    }

    func testInterpolatedHeightNeedsTwoPoints() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let single = [TideData(date: base, height: 1.0, isHighTide: false, coefficient: nil)]
        XCTAssertNil(TideCalculator.interpolatedHeight(at: base, sortedTides: single))
    }

    func testCurrentStateTrendRising() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = makeCycle(base: base)
        let state = TideCalculator.currentState(at: base.addingTimeInterval(3 * 3600), sortedTides: tides)
        XCTAssertNotNil(state)
        XCTAssertEqual(state!.trend, .rising)              // prochaine = pleine mer
        XCTAssertEqual(state!.currentHeight, 3.0, accuracy: 0.0001)
        XCTAssertEqual(state!.percentToNextTide, 0.5, accuracy: 0.0001)
    }

    func testCurrentStateSlackJustAfterLowTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = makeCycle(base: base)
        // Juste après la basse mer (T+1min) → étale basse (la marée précédente est basse).
        let state = TideCalculator.currentState(at: base.addingTimeInterval(60), sortedTides: tides)
        XCTAssertEqual(state!.trend, .lowSlack)
    }

    func testCurrentStateSlackJustAfterHighTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Série 3 points : basse(0h) → pleine(6h) → basse(12h).
        let tides = [
            TideData(date: base,                               height: 1.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600),  height: 5.0, isHighTide: true,  coefficient: 95),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 1.2, isHighTide: false, coefficient: nil),
        ]
        // Juste après la pleine mer (T+6h+1min) → étale haute.
        let state = TideCalculator.currentState(at: base.addingTimeInterval(6 * 3600 + 60), sortedTides: tides)
        XCTAssertEqual(state!.trend, .highSlack)
    }

    func testCurrentStateFallingAfterHighTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = [
            TideData(date: base,                               height: 1.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600),  height: 5.0, isHighTide: true,  coefficient: 95),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 1.2, isHighTide: false, coefficient: nil),
        ]
        // Mi-chemin entre pleine et basse → descendante.
        let state = TideCalculator.currentState(at: base.addingTimeInterval(9 * 3600), sortedTides: tides)
        XCTAssertEqual(state!.trend, .falling)
    }

    func testRuleOfTwelfths() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = makeCycle(base: base)
        let t = TideCalculator.ruleOfTwelfths(at: base.addingTimeInterval(3 * 3600), sortedTides: tides)
        XCTAssertNotNil(t)
        XCTAssertEqual(t!.currentHour, 4)                  // 3h écoulées → 4e heure de marée
        XCTAssertEqual(t!.currentFlowTwelfths, 3)          // douzièmes [1,2,3,3,2,1][3] = 3
        XCTAssertTrue(t!.isRising)
        XCTAssertEqual(t!.totalRange, 4.0, accuracy: 0.0001)
        XCTAssertEqual(t!.estimatedFlowMeters!, 4.0 * 3 / 12, accuracy: 0.0001)
    }

    func testStatistics() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = [
            TideData(date: base,                               height: 1.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600),  height: 5.0, isHighTide: true,  coefficient: 100),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 2.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(18 * 3600), height: 6.0, isHighTide: true,  coefficient: 80),
        ]
        let s = TideCalculator.statistics(for: tides)
        XCTAssertEqual(s.averageHighTide, 5.5, accuracy: 0.0001)
        XCTAssertEqual(s.averageLowTide, 1.5, accuracy: 0.0001)
        XCTAssertEqual(s.maxHighTide, 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.minLowTide, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s.tidalRange, 4.0, accuracy: 0.0001)
        XCTAssertEqual(s.averageCoefficient!, 90.0, accuracy: 0.0001)
    }

    func testCurrentCoefficientPicksNearestHighTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = [
            TideData(date: base,                               height: 5.0, isHighTide: true,  coefficient: 40),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 6.0, isHighTide: true,  coefficient: 110),
        ]
        // Plus proche de la 2e pleine mer → coef 110.
        let coef = TideCalculator.currentCoefficient(at: base.addingTimeInterval(11 * 3600), tides: tides)
        XCTAssertEqual(coef, 110)
    }

    // MARK: - Données partagées widget (WidgetSharedData)

    /// Donnée « ancienne » (sans timeZoneIdentifier) : doit décoder sans planter
    /// et retomber sur le fuseau de l'appareil.
    func testWidgetSharedDataDecodesLegacyWithoutTimeZone() throws {
        let json = """
        {"portName":"Brest","nextTideDate":0,"nextTideHeight":5.0,"nextTideIsHigh":true,"currentHeight":3.0,"trend":"Montante","updatedAt":0}
        """.data(using: .utf8)!
        let data = try JSONDecoder().decode(WidgetSharedData.self, from: json)
        XCTAssertEqual(data.portName, "Brest")
        XCTAssertNil(data.timeZoneIdentifier)
        XCTAssertEqual(data.timeZone, .current)
        XCTAssertTrue(data.allTides.isEmpty)
    }

    /// Donnée récente : le fuseau du port est conservé.
    func testWidgetSharedDataPreservesTimeZone() throws {
        let json = """
        {"portName":"Papeete","nextTideDate":0,"nextTideHeight":5.0,"nextTideIsHigh":true,"currentHeight":3.0,"trend":"Montante","updatedAt":0,"timeZoneIdentifier":"Pacific/Tahiti"}
        """.data(using: .utf8)!
        let data = try JSONDecoder().decode(WidgetSharedData.self, from: json)
        XCTAssertEqual(data.timeZoneIdentifier, "Pacific/Tahiti")
        XCTAssertEqual(data.timeZone.identifier, "Pacific/Tahiti")
    }

    func testWidgetSharedDataRoundTrip() throws {
        let original = WidgetSharedData(
            portName: "Nouméa", nextTideDate: Date(timeIntervalSince1970: 1000),
            nextTideHeight: 1.2, nextTideIsHigh: false, nextTideCoef: 75,
            currentHeight: 1.0, trend: "Descendante", updatedAt: Date(timeIntervalSince1970: 900),
            timeZoneIdentifier: "Pacific/Noumea"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WidgetSharedData.self, from: encoded)
        XCTAssertEqual(decoded.portName, "Nouméa")
        XCTAssertEqual(decoded.timeZoneIdentifier, "Pacific/Noumea")
        XCTAssertEqual(decoded.nextTideCoef, 75)
    }

    // MARK: - Résolution autonome des marées (widget / Watch)

    private func simpleTides(base: Date) -> [SimpleTide] {
        [
            SimpleTide(date: base,                               height: 1.0, isHigh: false, coefficient: nil),
            SimpleTide(date: base.addingTimeInterval(6 * 3600),  height: 5.0, isHigh: true,  coefficient: 90),
            SimpleTide(date: base.addingTimeInterval(12 * 3600), height: 1.2, isHigh: false, coefficient: nil),
            SimpleTide(date: base.addingTimeInterval(18 * 3600), height: 6.0, isHigh: true,  coefficient: 80),
        ]
    }

    func testResolveTidesBracketsCorrectly() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = simpleTides(base: base)
        let r = resolveTides(from: tides, at: base.addingTimeInterval(3 * 3600))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.previous.date, base)                                  // basse 0h
        XCTAssertEqual(r!.next.date, base.addingTimeInterval(6 * 3600))         // pleine 6h
        XCTAssertEqual(r!.second?.date, base.addingTimeInterval(12 * 3600))     // basse 12h
    }

    func testResolveTidesNilBeforeFirstTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = simpleTides(base: base)
        // Avant la première marée → pas de "previous" exploitable.
        XCTAssertNil(resolveTides(from: tides, at: base.addingTimeInterval(-3600)))
    }

    func testResolveTidesNilAfterLastTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = simpleTides(base: base)
        XCTAssertNil(resolveTides(from: tides, at: base.addingTimeInterval(19 * 3600)))
    }

    func testResolveTidesNeedsTwoPoints() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let one = [SimpleTide(date: base, height: 1.0, isHigh: false, coefficient: nil)]
        XCTAssertNil(resolveTides(from: one, at: base))
    }

    func testResolvedSharedDataInterpolatesAndPicksCoef() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = simpleTides(base: base)
        let raw = WidgetSharedData(
            portName: "Test", nextTideDate: base, nextTideHeight: 0, nextTideIsHigh: false,
            nextTideCoef: nil, currentHeight: 0, trend: "—", updatedAt: base,
            allTides: tides, timeZoneIdentifier: "Europe/Paris"
        )
        let resolved = resolvedSharedData(from: raw, at: base.addingTimeInterval(3 * 3600))
        // À mi-chemin basse→pleine : hauteur interpolée = 3.0, prochaine = pleine mer 6h.
        XCTAssertEqual(resolved.currentHeight, 3.0, accuracy: 0.0001)
        XCTAssertEqual(resolved.nextTideDate, base.addingTimeInterval(6 * 3600))
        XCTAssertTrue(resolved.nextTideIsHigh)
        XCTAssertEqual(resolved.todayCoef, 90)          // pleine mer porteuse la plus proche
        XCTAssertEqual(resolved.timeZoneIdentifier, "Europe/Paris") // fuseau préservé
    }

    // MARK: - Calcul solaire (SolarCalculator)

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testSolarSunriseBeforeSunset() {
        // Brest, solstice d'été → jour long (~16 h).
        let sun = SolarCalculator.sunriseSunset(latitude: 48.39, longitude: -4.49, date: utcDate(2025, 6, 21))
        XCTAssertNotNil(sun)
        XCTAssertLessThan(sun!.sunrise, sun!.sunset)
        let hours = sun!.sunset.timeIntervalSince(sun!.sunrise) / 3600
        XCTAssertGreaterThan(hours, 14)
        XCTAssertLessThan(hours, 17)
    }

    func testSolarWinterShortDay() {
        // Brest, solstice d'hiver → jour court (~8 h).
        let sun = SolarCalculator.sunriseSunset(latitude: 48.39, longitude: -4.49, date: utcDate(2025, 12, 21))
        XCTAssertNotNil(sun)
        let hours = sun!.sunset.timeIntervalSince(sun!.sunrise) / 3600
        XCTAssertGreaterThan(hours, 7)
        XCTAssertLessThan(hours, 9.5)
    }

    func testSolarEquatorRoughlyTwelveHours() {
        // À l'équateur, le jour dure ~12 h toute l'année.
        let sun = SolarCalculator.sunriseSunset(latitude: 0.0, longitude: 0.0, date: utcDate(2025, 3, 21))
        XCTAssertNotNil(sun)
        let hours = sun!.sunset.timeIntervalSince(sun!.sunrise) / 3600
        XCTAssertEqual(hours, 12, accuracy: 0.6)
    }

    // MARK: - Scoring kite : gate hauteur d'eau du spot

    @MainActor
    func testKiteWaterGateBlocksLowWater() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Marée : basse 0,5 m à T → pleine 3,0 m à T+6h.
        let tides = [
            TideData(date: base,                              height: 0.5, isHighTide: false, coefficient: 60),
            TideData(date: base.addingTimeInterval(6 * 3600), height: 3.0, isHighTide: true,  coefficient: 60),
        ]
        let goodWind = ActivityScoreService.SimpleWeather(
            windSpeedKmh: 20, windGustKmh: 24, temperatureCelsius: 18, windDirectionDeg: 270)
        let spot = SpotConfig(minWaterHeight: 2.0, spotType: .basin)  // bassin, 2 m mini

        // Marée basse (0,5 m < 2 m) → PAS d'eau → score plafonné bas malgré un vent idéal.
        let low = ActivityScoreService.shared.calculateScore(
            for: .kitesurfing, tideData: tides, simpleWeather: goodWind,
            marineConditions: nil, currentTime: base, spot: spot)
        XCTAssertLessThan(low.score, 35)

        // Pleine mer (3,0 m ≥ 2 m) + vent idéal → bonne sortie.
        let high = ActivityScoreService.shared.calculateScore(
            for: .kitesurfing, tideData: tides, simpleWeather: goodWind,
            marineConditions: nil, currentTime: base.addingTimeInterval(6 * 3600), spot: spot)
        XCTAssertGreaterThan(high.score, 60)
    }

    // MARK: - Helpers de date

    func testCalendarInTimeZoneUsesGivenZone() {
        let tz = TimeZone(identifier: "Pacific/Tahiti")!
        let cal = Calendar.inTimeZone(tz)
        XCTAssertEqual(cal.timeZone, tz)
    }

    /// 1970-01-01 00:00 UTC → 14:00 la veille à Tahiti (UTC-10).
    func testFormatTideTimeAppliesPortTimeZone() {
        let instant = Date(timeIntervalSince1970: 0)
        let tahiti = TimeZone(identifier: "Pacific/Tahiti")!
        XCTAssertEqual(formatTideTime(instant, in: tahiti), "14:00")
        let paris = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(formatTideTime(instant, in: paris), "01:00") // CET en janvier
    }

    // MARK: - Weameter parsing

    func testWeameterFirstNumberParsesLocalizedStrings() {
        // Virgule décimale française + unité accolée
        XCTAssertEqual(WeameterService.firstNumber("12,7 n&oelig;uds") ?? -1, 12.7, accuracy: 0.001)
        // Direction avec entité HTML degré
        XCTAssertEqual(WeameterService.firstNumber("234&#176;") ?? -1, 234, accuracy: 0.001)
        XCTAssertEqual(WeameterService.firstNumber("234°") ?? -1, 234, accuracy: 0.001)
        // Coordonnée négative
        XCTAssertEqual(WeameterService.firstNumber("-1.108622") ?? 0, -1.108622, accuracy: 0.000001)
        XCTAssertNil(WeameterService.firstNumber(nil))
        XCTAssertNil(WeameterService.firstNumber("pas de chiffre"))
    }

    // MARK: - Pêche à pied : localisation des espèces

    func testCoastTypeClassifiesArcachonAsBasin() {
        // Andernos-les-Bains (Bassin d'Arcachon) : sableux/vaseux, pas de roche.
        let basin = CoastType.at(latitude: 44.742, longitude: -1.108)
        XCTAssertFalse(basin.habitats.contains(.roche), "Le Bassin ne doit pas exposer d'habitat rocheux")
        XCTAssertTrue(basin.habitats.contains(.sableVase))
        // Bretagne (Roscoff) : côte rocheuse → roche praticable.
        let brittany = CoastType.at(latitude: 48.72, longitude: -3.98)
        XCTAssertTrue(brittany.habitats.contains(.roche))
    }

    func testArcachonNeverOffersTourteau() {
        // Invariant : dans le Bassin d'Arcachon (sableux/vaseux) aucune espèce rocheuse
        // — donc jamais de tourteau (habitat .roche).
        let basinHabitats: Set<ShellfishHabitat> = [.sable, .vase, .sableVase]
        for month in 1...12 {
            let local = ShellfishSpecies.localInSeason(month: month, latitude: 44.742, longitude: -1.108)
            XCTAssertFalse(local.species.isEmpty, "Le Bassin doit avoir des espèces au mois \(month)")
            for sp in local.species {
                XCTAssertTrue(basinHabitats.contains(sp.habitat),
                              "\(sp.id) (\(sp.habitat.rawValue)) ne devrait pas être dans le Bassin (mois \(month))")
            }
            XCTAssertFalse(local.species.contains { $0.id.contains("tourteau") },
                           "Pas de tourteau dans le Bassin (mois \(month))")
        }
    }

    func testNDBCParsesWindAndMetrics() {
        // Deux lignes d'en-tête + une bouée valide + une sans vent (MM) → 1 station.
        let sample = """
        #STN       LAT      LON  YYYY MM DD hh mm WDIR WSPD   GST WVHT  DPD APD MWD   PRES  PTDY  ATMP  WTMP  DEWP  VIS   TIDE
        #text      deg      deg   yr mo day hr mn degT  m/s   m/s   m   sec sec degT   hPa   hPa  degC  degC  degC  nmi     ft
        41001    34.70   -72.70 2026 06 04 15 00 200  10.0  12.0  1.5   8  6 180 1015.0    MM  22.0  24.0  18.0   MM     MM
        99999    10.00    10.00 2026 06 04 15 00   MM    MM    MM   MM  MM MM  MM     MM    MM    MM    MM    MM   MM     MM
        """
        let stations = NDBCService.parse(sample)
        XCTAssertEqual(stations.count, 1, "Seule la bouée avec vent doit être retenue")
        let s = stations[0]
        XCTAssertEqual(s.id, "ndbc_41001")
        XCTAssertEqual(s.source, .ndbc)
        XCTAssertEqual(s.latitude, 34.70, accuracy: 0.001)
        guard let r = s.reading else { return XCTFail("reading manquante") }
        XCTAssertEqual(r.speedAvgKmh, 10.0 * 3.6, accuracy: 0.01)   // m/s → km/h
        XCTAssertEqual(r.gustKmh ?? 0, 12.0 * 3.6, accuracy: 0.01)
        XCTAssertEqual(r.directionDegrees, 200, accuracy: 0.01)
        XCTAssertEqual(r.pressureHpa ?? 0, 1015.0, accuracy: 0.01)
        XCTAssertEqual(r.temperatureC ?? 0, 22.0, accuracy: 0.01)
        XCTAssertEqual(r.dewpointC ?? 0, 18.0, accuracy: 0.01)
        XCTAssertTrue(r.hasExtraMetrics)
    }

    func testWeameterUnitConversionToKmh() {
        // 12.7 nœuds → 23.52 km/h (×1.852)
        XCTAssertEqual(WeameterService.toKmh(12.7, unitLabel: " n&oelig;uds"), 12.7 * 1.852, accuracy: 0.01)
        // m/s → ×3.6
        XCTAssertEqual(WeameterService.toKmh(10, unitLabel: " m/s"), 36, accuracy: 0.01)
        // mph → ×1.609344
        XCTAssertEqual(WeameterService.toKmh(10, unitLabel: " mph"), 16.09344, accuracy: 0.01)
        // km/h ou inconnu → inchangé
        XCTAssertEqual(WeameterService.toKmh(25, unitLabel: " km/h"), 25, accuracy: 0.01)
        XCTAssertEqual(WeameterService.toKmh(25, unitLabel: nil), 25, accuracy: 0.01)
    }

    // MARK: - Ensemble vent multi-modèles (WindEnsemble.blend)

    /// Moyenne PONDÉRÉE : AROME (0,5) prioritaire sur ICON (0,3) et GFS (0,2).
    func testWindEnsembleWeightedSpeed() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: 20, gust: 30, dir: 270),
            WindModelReading(weight: 0.30, speed: 10, gust: 18, dir: 270),
            WindModelReading(weight: 0.20, speed: 0,  gust: 5,  dir: 270),
        ])
        XCTAssertNotNil(r)
        // 0.5*20 + 0.3*10 + 0.2*0 = 13
        XCTAssertEqual(r!.speed, 13, accuracy: 0.001)
        // 0.5*30 + 0.3*18 + 0.2*5 = 21.4
        XCTAssertEqual(r!.gust ?? -1, 21.4, accuracy: 0.001)
        XCTAssertEqual(r!.count, 3)
    }

    /// Modèles d'accord (même vitesse) → fiabilité maximale.
    func testWindEnsembleAgreementHighConfidence() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: 15, gust: nil, dir: 200),
            WindModelReading(weight: 0.30, speed: 15, gust: nil, dir: 200),
            WindModelReading(weight: 0.20, speed: 15, gust: nil, dir: 200),
        ])
        XCTAssertEqual(r?.speed ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(r?.confidence ?? -1, 1.0, accuracy: 0.001)  // écart nul → 1,0
        XCTAssertNil(r?.gust)  // aucun modèle ne fournit de rafale
    }

    /// Fort désaccord (grand écart de vitesse) → fiabilité plancher (0,2).
    func testWindEnsembleDisagreementLowConfidence() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: 5,  gust: nil, dir: 0),
            WindModelReading(weight: 0.30, speed: 40, gust: nil, dir: 0),
        ])
        // écart 35 km/h >> 18 → clamp à 0,2
        XCTAssertEqual(r?.confidence ?? -1, 0.2, accuracy: 0.001)
    }

    /// Un seul modèle disponible → pas de recoupement → fiabilité neutre (0,55).
    func testWindEnsembleSingleModelNeutralConfidence() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: 22, gust: 33, dir: 315),
            WindModelReading(weight: 0.30, speed: nil, gust: nil, dir: nil),
            WindModelReading(weight: 0.20, speed: nil, gust: nil, dir: nil),
        ])
        XCTAssertEqual(r?.speed ?? -1, 22, accuracy: 0.001)  // seul AROME compte
        XCTAssertEqual(r?.confidence ?? -1, 0.55, accuracy: 0.001)
        XCTAssertEqual(r?.count, 1)
    }

    /// Direction = moyenne CIRCULAIRE (gère le passage 360°/0°).
    func testWindEnsembleCircularDirection() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: 12, gust: nil, dir: 350),
            WindModelReading(weight: 0.30, speed: 12, gust: nil, dir: 10),
        ])
        let dir = r?.dir ?? -1
        // moyenne autour de 0°, pas ~180° (preuve que ce n'est pas une moyenne arithmétique)
        XCTAssertTrue(dir > 345 || dir < 15, "Direction circulaire attendue près de 0°, obtenu \(dir)")
    }

    /// Aucun modèle avec vitesse → nil (heure ignorée).
    func testWindEnsembleEmptyReturnsNil() {
        let r = WindEnsemble.blend([
            WindModelReading(weight: 0.50, speed: nil, gust: nil, dir: nil),
            WindModelReading(weight: 0.30, speed: nil, gust: 20, dir: 180),
        ])
        XCTAssertNil(r)
    }

    // MARK: - Gate vent « Sorties Parfaites » (ActivityScoreService.windPracticable)

    /// Sous la limite rider − 20% → JAMAIS proposé ; au-delà → tempête, rejeté.
    func testWindGatePracticableRange() {
        let min = 12.0
        // À la limite et au-dessus → praticable
        XCTAssertTrue(ActivityScoreService.windPracticable(windKmh: 12, minWindKmh: min))
        XCTAssertTrue(ActivityScoreService.windPracticable(windKmh: 25, minWindKmh: min))
        // Exactement 80% de la limite (tolérance) → encore praticable
        XCTAssertTrue(ActivityScoreService.windPracticable(windKmh: 9.6, minWindKmh: min))
        // Sous la tolérance de 20% → rejeté
        XCTAssertFalse(ActivityScoreService.windPracticable(windKmh: 9.5, minWindKmh: min))
        XCTAssertFalse(ActivityScoreService.windPracticable(windKmh: 0, minWindKmh: min))
        // Plafond tempête (50 km/h)
        XCTAssertTrue(ActivityScoreService.windPracticable(windKmh: 49.9, minWindKmh: min))
        XCTAssertFalse(ActivityScoreService.windPracticable(windKmh: 50, minWindKmh: min))
        XCTAssertFalse(ActivityScoreService.windPracticable(windKmh: 65, minWindKmh: min))
    }

    /// La tolérance suit la limite : un rider exigeant (18 km/h) rejette ce qu'un autre (8) accepte.
    func testWindGateScalesWithRiderLimit() {
        // Rider 18 km/h : 14 km/h est sous 80% (14.4) → rejeté
        XCTAssertFalse(ActivityScoreService.windPracticable(windKmh: 14, minWindKmh: 18))
        // Rider 8 km/h : 14 km/h est largement au-dessus → praticable
        XCTAssertTrue(ActivityScoreService.windPracticable(windKmh: 14, minWindKmh: 8))
    }

    // MARK: - Ruban Vent & Marée (fenêtres GO)

    private func mkForecast(_ base: Date, _ h: Int, _ speed: Double) -> HourlyForecast {
        HourlyForecast(time: base.addingTimeInterval(Double(h) * 3600), windSpeedKmh: speed,
                       windGustKmh: speed * 1.3, windDirection: 315, temperature: nil,
                       weatherCode: nil, waveHeight: nil, wavePeriod: nil, swellHeight: nil, swellPeriod: nil)
    }

    private func mkForecastDir(_ base: Date, _ h: Int, _ speed: Double, _ dir: Double) -> HourlyForecast {
        HourlyForecast(time: base.addingTimeInterval(Double(h) * 3600), windSpeedKmh: speed,
                       windGustKmh: speed * 1.3, windDirection: dir, temperature: nil,
                       weatherCode: nil, waveHeight: nil, wavePeriod: nil, swellHeight: nil, swellPeriod: nil)
    }

    /// Les fenêtres GO = heures consécutives où le vent ∈ plage ET de jour.
    func testGoWindows() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]   // tout le jour
        // h0=5 (faible), h1=20, h2=25, h3=22 (∈15-35), h4=60 & h5=62 (trop fort ×2 h), h6=18 (∈).
        // Le trou de 2 h n'est PAS comblé → 2 fenêtres distinctes.
        let fc = [mkForecast(base,0,5), mkForecast(base,1,20), mkForecast(base,2,25),
                  mkForecast(base,3,22), mkForecast(base,4,60), mkForecast(base,5,62), mkForecast(base,6,18)]
        let gos = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: sun)
        XCTAssertEqual(gos.count, 2)
        XCTAssertEqual(gos[0].start, base.addingTimeInterval(3600))        // h1
        XCTAssertEqual(gos[0].end, base.addingTimeInterval(4 * 3600))      // h3 + 1h
        // De nuit (au-delà du coucher) → aucune fenêtre.
        let night = [(sunrise: base.addingTimeInterval(-12 * 3600), sunset: base.addingTimeInterval(-1))]
        XCTAssertTrue(WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: night).isEmpty)
    }

    /// Spot à seuil (bassin) : même avec du vent ∈ plage ET de jour, pas de fenêtre GO
    /// quand la hauteur d'eau est sous le minimum requis.
    func testGoWindowsWaterGate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]   // tout le jour
        // Vent ∈ plage sur h0..h3, mais l'eau n'est suffisante (≥1.5 m) qu'à h2 et h3.
        let fc = [mkForecast(base,0,20), mkForecast(base,1,22),
                  mkForecast(base,2,21), mkForecast(base,3,23)]
        let waterByHour: [Double] = [0.5, 1.0, 1.8, 2.0]
        let height: (Date) -> Double? = { d in
            let h = Int(d.timeIntervalSince(base) / 3600)
            return (0..<waterByHour.count).contains(h) ? waterByHour[h] : nil
        }
        // Sans seuil : une seule fenêtre couvrant h0..h3.
        let noGate = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: sun)
        XCTAssertEqual(noGate.count, 1)
        // Avec seuil 1.5 m : la fenêtre ne démarre qu'à h2 (eau suffisante).
        let gated = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: sun,
                                              minWaterHeight: 1.5, tideHeightAt: height)
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated[0].start, base.addingTimeInterval(2 * 3600))   // h2
        XCTAssertEqual(gated[0].end, base.addingTimeInterval(4 * 3600))     // h3 + 1h
    }

    // MARK: - ActivityGoPlanner (calendrier 7 jours)

    func testSportWindowsFromConditions() {
        // Kitefoil, vent praticable 18–46 km/h. h0=12 (sous), h1=25, h2=30 (∈), h3=60 (au-dessus).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        let fc = [mkForecast(base, 0, 12), mkForecast(base, 1, 25), mkForecast(base, 2, 30), mkForecast(base, 3, 60)]
        let setup = SportSetup(sport: .kitefoil, enabled: true,
                               conditions: [AlertCondition(type: .windSpeed, operator1: .between, value1: 18, value2: 46)])
        let wins = ActivityGoPlanner.windows(for: setup, forecasts: fc, sunTimes: sun, tideData: [])
        XCTAssertEqual(wins.count, 1)
        XCTAssertEqual(wins[0].start, base.addingTimeInterval(3600))       // h1
        XCTAssertEqual(wins[0].end, base.addingTimeInterval(3 * 3600))     // h2 + 1h
    }

    func testSportEmptyConditionsNoWindows() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        let fc = [mkForecast(base, 0, 25), mkForecast(base, 1, 25)]
        let setup = SportSetup(sport: .wing, enabled: true, conditions: [])
        XCTAssertTrue(ActivityGoPlanner.windows(for: setup, forecasts: fc, sunTimes: sun, tideData: []).isEmpty,
                      "sans condition → pas de fenêtre")
    }

    func testSportNoWindowsAtNight() {
        // Vent OK partout mais de nuit → aucune fenêtre.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let night = [(sunrise: base.addingTimeInterval(-12 * 3600), sunset: base.addingTimeInterval(-1))]
        let fc = [mkForecast(base, 0, 25), mkForecast(base, 1, 25), mkForecast(base, 2, 25)]
        let setup = SportSetup(sport: .kitesurf, enabled: true,
                               conditions: [AlertCondition(type: .windSpeed, operator1: .between, value1: 18, value2: 46)])
        XCTAssertTrue(ActivityGoPlanner.windows(for: setup, forecasts: fc, sunTimes: night, tideData: []).isEmpty)
    }

    func testSportIgnoresWindEstablishingCondition() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        let fc = [mkForecast(base, 0, 25), mkForecast(base, 1, 25)]
        // Vent OK + une condition « le vent s'établit » (non projetable) : doit être IGNORÉE,
        // pas rendre le sport silencieusement « jamais GO ».
        let mixed = SportSetup(sport: .kitesurf, enabled: true, conditions: [
            AlertCondition(type: .windSpeed, operator1: .between, value1: 18, value2: 46),
            AlertCondition(type: .windEstablishing, operator1: .greaterThan, value1: 28, value2: 20),
        ])
        XCTAssertFalse(ActivityGoPlanner.windows(for: mixed, forecasts: fc, sunTimes: sun, tideData: []).isEmpty,
                       "windEstablishing ignoré → le sport reste GO sur ses autres conditions")
        // Seulement windEstablishing → aucune fenêtre exploitable.
        let only = SportSetup(sport: .wing, enabled: true, conditions: [
            AlertCondition(type: .windEstablishing, operator1: .greaterThan, value1: 28, value2: 20),
        ])
        XCTAssertTrue(ActivityGoPlanner.windows(for: only, forecasts: fc, sunTimes: sun, tideData: []).isEmpty)
    }

    func testSportPlanGroupsByDayAndDirection() {
        // Sport avec direction d'Ouest (270 ± 45). h0 vent d'Est (exclu), h1–h2 d'Ouest (OK).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        let fc = [mkForecastDir(base, 0, 30, 90), mkForecastDir(base, 1, 30, 270), mkForecastDir(base, 2, 30, 270)]
        let setup = SportSetup(sport: .wing, enabled: true, conditions: [
            AlertCondition(type: .windSpeed, operator1: .between, value1: 18, value2: 46),
            AlertCondition(type: .windDirection, operator1: .equals, value1: 270, value2: 45,
                           windDirectionCenter: 270, windDirectionSpread: 45),
        ])
        let wins = ActivityGoPlanner.windows(for: setup, forecasts: fc, sunTimes: sun, tideData: [])
        XCTAssertEqual(wins.count, 1)
        XCTAssertEqual(wins[0].start, base.addingTimeInterval(3600), "vent d'Est exclu → départ à h1")
    }

    func testGoWindowsOffshoreGate() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        // Spot face à l'Ouest (mer au cap 270°) → offshore = vent venant de l'Est (90°).
        // h0 : vent d'Est (offshore, exclu) ; h1–h2 : vent d'Ouest (onshore, OK).
        let fc = [mkForecastDir(base, 0, 25, 90),
                  mkForecastDir(base, 1, 25, 270),
                  mkForecastDir(base, 2, 25, 270)]
        let gated = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 40,
                                              sunTimes: sun, shoreOrientation: 270)
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated[0].start, base.addingTimeInterval(3600), "offshore h0 exclu → départ à h1")
        // Sans orientation : la fenêtre couvre h0..h2.
        let ungated = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 40, sunTimes: sun)
        XCTAssertEqual(ungated.first?.start, base)
    }

    func testGoWindowsBridgesBriefDip() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        // OK h0,h1 ; creux h2 (hors plage) ; OK h3,h4 → un seul trou d'1 h doit être comblé.
        let fc = [mkForecast(base, 0, 25), mkForecast(base, 1, 25), mkForecast(base, 2, 5),
                  mkForecast(base, 3, 25), mkForecast(base, 4, 25)]
        let wins = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 40, sunTimes: sun)
        XCTAssertEqual(wins.count, 1, "un creux d'1 h ne doit pas fragmenter la fenêtre")
        XCTAssertEqual(wins[0].start, base)
        XCTAssertEqual(wins[0].end, base.addingTimeInterval(5 * 3600))   // h4 + 1h
        // Un creux de 2 h reste une coupure.
        let fc2 = [mkForecast(base, 0, 25), mkForecast(base, 1, 25), mkForecast(base, 2, 5),
                   mkForecast(base, 3, 5), mkForecast(base, 4, 25), mkForecast(base, 5, 25)]
        XCTAssertEqual(WindTidePlanner.goWindows(forecasts: fc2, minKmh: 15, maxKmh: 40, sunTimes: sun).count, 2)
    }

    func testGoWindowsWaterFailSafe() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(24 * 3600))]
        let fc = [mkForecast(base, 0, 20), mkForecast(base, 1, 22), mkForecast(base, 2, 21)]
        // Eau requise (1,5 m) mais marée indispo (tideHeightAt nil).
        let failOpen = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: sun,
                                                 minWaterHeight: 1.5, tideHeightAt: nil)
        XCTAssertEqual(failOpen.count, 1, "par défaut : fail-open (fenêtre conservée)")
        let failSafe = WindTidePlanner.goWindows(forecasts: fc, minKmh: 15, maxKmh: 35, sunTimes: sun,
                                                 minWaterHeight: 1.5, tideHeightAt: nil,
                                                 blockWhenWaterUnknown: true)
        XCTAssertTrue(failSafe.isEmpty, "eau requise non vérifiable → pas de fenêtre (sécurité)")
    }

    func testWindCardinalAndDaylight() {
        XCTAssertEqual(WindTidePlanner.cardinal(0), "N")
        XCTAssertEqual(WindTidePlanner.cardinal(90), "E")
        XCTAssertEqual(WindTidePlanner.cardinal(180), "S")
        XCTAssertEqual(WindTidePlanner.cardinal(315), "NO")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sun = [(sunrise: base, sunset: base.addingTimeInterval(8 * 3600))]
        XCTAssertTrue(WindTidePlanner.isDaylight(base.addingTimeInterval(3600), sunTimes: sun))
        XCTAssertFalse(WindTidePlanner.isDaylight(base.addingTimeInterval(10 * 3600), sunTimes: sun))
    }

    // MARK: - Cohérence des arguments harmoniques (anti-régression V₀)

    /// Le taux de variation de V₀ DOIT égaler `vitesse − espèce·15°/h` pour chaque
    /// constituant (sinon l'argument astronomique est faux). Ce test attrape directement
    /// le bug historique sur MU2/NU2/L2/LAM2 : leurs V₀ évoluaient au mauvais rythme.
    func testConstituentV0SpeedConsistency() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a0 = AstronomicalArguments(date: t0)
        let a1 = AstronomicalArguments(date: t0.addingTimeInterval(3600)) // +1 h
        let cases: [(id: String, speed: Double, species: Double)] = [
            ("M2", ConstituentSpeed.M2, 2), ("S2", ConstituentSpeed.S2, 2),
            ("N2", ConstituentSpeed.N2, 2), ("K2", ConstituentSpeed.K2, 2),
            ("MU2", ConstituentSpeed.MU2, 2), ("NU2", ConstituentSpeed.NU2, 2),
            ("L2", ConstituentSpeed.L2, 2), ("LAM2", ConstituentSpeed.LAM2, 2),
            ("K1", ConstituentSpeed.K1, 1), ("O1", ConstituentSpeed.O1, 1),
            ("P1", ConstituentSpeed.P1, 1), ("Q1", ConstituentSpeed.Q1, 1),
            ("M4", ConstituentSpeed.M4, 4), ("Mf", ConstituentSpeed.Mf, 0),
        ]
        func wrap180(_ x: Double) -> Double {
            var v = x.truncatingRemainder(dividingBy: 360)
            if v > 180 { v -= 360 }; if v < -180 { v += 360 }
            return v
        }
        for c in cases {
            let measured = wrap180(a1.V0(for: c.id) - a0.V0(for: c.id))
            let expected = wrap180(c.speed - c.species * 15.0)
            XCTAssertEqual(measured, expected, accuracy: 0.02,
                           "Argument V₀ incohérent avec la vitesse pour \(c.id)")
        }
    }

    /// Le coefficient utilise le DEMI-MARNAGE (PM−BM)/2 et est invariant par décalage
    /// saisonnier (Sa/Ssa) — vives-eaux moyennes ≈ 100, mortes-eaux ≈ 50.
    func testCoefficientUsesHalfRangeAndIsSeasonInvariant() {
        let h = PortHarmonics(id: "TEST", meanSeaLevel: 3.0, constituents: [
            TidalConstituent(id: "M2", speed: ConstituentSpeed.M2, amplitude: 2.0, phase: 0),
            TidalConstituent(id: "S2", speed: ConstituentSpeed.S2, amplitude: 0.7, phase: 0),
        ])
        // Unité = M2+S2 = 2.7 m. Vives-eaux moyennes : PM=Z0+2.7, BM=Z0−2.7 → coef 100.
        let springs = HarmonicTideEngine.estimateCoefficient(highTideHeight: 5.7, lowTideHeight: 0.3, harmonics: h)
        XCTAssertEqual(springs, 100)
        // Marnage IDENTIQUE décalé de +0.5 m (effet saisonnier) → coef inchangé.
        let shifted = HarmonicTideEngine.estimateCoefficient(highTideHeight: 6.2, lowTideHeight: 0.8, harmonics: h)
        XCTAssertEqual(shifted, springs)
        // Mortes-eaux (marnage moitié) → coef 50.
        let neaps = HarmonicTideEngine.estimateCoefficient(highTideHeight: 4.35, lowTideHeight: 1.65, harmonics: h)
        XCTAssertEqual(neaps, 50)
    }

    /// Coefficient SHOM NATIONAL dérivé du marnage de Brest : le demi-marnage égal à
    /// l'ancrage coef-95 donne 95, le double est clampé à 120.
    func testNationalCoefficientFromBrestRange() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let brestTides = [
            TideData(date: base,                              height: 0.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600), height: 5.4, isHighTide: true,  coefficient: nil),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 0.0, isHighTide: false, coefficient: nil),
        ]
        // Marnage montant = (5.4 − 0)/2 = 2.7 m = ancrage → coef 2.7/2.7×94.4 ≈ 94.
        let coef = HarmonicTideEngine.shomCoefficient(
            at: base.addingTimeInterval(6 * 3600), brestTides: brestTides, brestUnit: 2.7)
        XCTAssertEqual(coef, 94)
        // applyNationalCoefficients réécrit le coef des PM et laisse les BM à nil.
        let portTides = [
            TideData(date: base.addingTimeInterval(6 * 3600), height: 3.1, isHighTide: true, coefficient: 70),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 0.4, isHighTide: false, coefficient: nil),
        ]
        let out = HarmonicTideEngine.applyNationalCoefficients(portTides, brestTides: brestTides, coef95SemiRange: 2.7)
        XCTAssertEqual(out[0].coefficient, 94)   // PM → coef national (et non 70 local)
        XCTAssertNil(out[1].coefficient)         // BM inchangée
    }

    /// Étale JUSTE AVANT la pleine mer : l'eau est quasi haute → étale HAUTE (l'ancien
    /// code utilisait la marée précédente des deux côtés → « étale basse » avant la PM).
    func testCurrentStateSlackJustBeforeHighTide() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tides = [
            TideData(date: base,                               height: 1.0, isHighTide: false, coefficient: nil),
            TideData(date: base.addingTimeInterval(6 * 3600),  height: 5.0, isHighTide: true,  coefficient: 95),
            TideData(date: base.addingTimeInterval(12 * 3600), height: 1.2, isHighTide: false, coefficient: nil),
        ]
        // 1 min AVANT la pleine mer (progress ≈ 0.997) → étale haute.
        let state = TideCalculator.currentState(at: base.addingTimeInterval(6 * 3600 - 60), sortedTides: tides)
        XCTAssertEqual(state!.trend, .highSlack)
    }

    /// Calcul solaire pour un port du Pacifique loin de Greenwich (Tahiti, lon ≈ -149,5).
    /// Avant le fix du report de jour UTC, le coucher revenait 24 h trop tôt (sunset <
    /// sunrise) → « Sorties Parfaites » cassées sur tout le Pacifique.
    func testSolarPacificPortDayLength() {
        let sun = SolarCalculator.sunriseSunset(latitude: -17.53, longitude: -149.57, date: utcDate(2025, 3, 21))
        XCTAssertNotNil(sun)
        XCTAssertLessThan(sun!.sunrise, sun!.sunset)
        let hours = sun!.sunset.timeIntervalSince(sun!.sunrise) / 3600
        XCTAssertEqual(hours, 12, accuracy: 1.0) // équinoxe ≈ 12 h
    }
}
