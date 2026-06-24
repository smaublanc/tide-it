//
//  PortCatalog.swift
//  Tide It
//
//  Charge et agrège les ports depuis les sources bundlées (SHOM, NOAA, TICON).
//  Enregistre aussi les constantes harmoniques dans HarmonicTideEngine.
//
//  Au lancement, TideService appelle `loadFrenchPorts()` (SHOM, léger, synchrone)
//  pour un démarrage immédiat, puis `loadWorldPortsInBackground()` (NOAA + TICON,
//  ~5 Mo) hors du thread principal, et enfin `register(_:)` pour les harmoniques.
//

import Foundation
import os.log

@MainActor
final class PortCatalog {
    static let shared = PortCatalog()

    private init() {}

    // MARK: - Mapping harmoniques partagé (NOAA + TICON)

    nonisolated private static let harmonicSpeedMapping: [String: Double] = [
        "M2": ConstituentSpeed.M2, "S2": ConstituentSpeed.S2,
        "N2": ConstituentSpeed.N2, "K2": ConstituentSpeed.K2,
        "K1": ConstituentSpeed.K1, "O1": ConstituentSpeed.O1,
        "P1": ConstituentSpeed.P1, "Q1": ConstituentSpeed.Q1,
        "J1": ConstituentSpeed.J1, "OO1": ConstituentSpeed.OO1,
        "M4": ConstituentSpeed.M4, "MS4": ConstituentSpeed.MS4,
        "MN4": ConstituentSpeed.MN4, "M6": ConstituentSpeed.M6,
        "2N2": ConstituentSpeed._2N2, "MU2": ConstituentSpeed.MU2,
        "NU2": ConstituentSpeed.NU2, "L2": ConstituentSpeed.L2,
        "T2": ConstituentSpeed.T2, "LAM2": ConstituentSpeed.LAM2,
        "2MS6": ConstituentSpeed._2MS6,
        "Mf": ConstituentSpeed.Mf, "Mm": ConstituentSpeed.Mm,
        "Ssa": ConstituentSpeed.Ssa, "Sa": ConstituentSpeed.Sa,
        "MSf": ConstituentSpeed.MSf,
    ]

    /// Lookup INSENSIBLE À LA CASSE → (id canonique, vitesse).
    /// Les JSON TICON/NOAA stockent les longue-période en MAJUSCULES (MF, MM, SSA,
    /// SA, MSF) alors que le moteur (V₀/f/u) attend Mf/Mm/Ssa/Sa/MSf : sans cette
    /// normalisation, ces 5 constituants étaient silencieusement rejetés pour les
    /// 3712 stations (et donc tous les ports, y compris français via rattachement).
    nonisolated private static let canonicalConstituent: [String: (id: String, speed: Double)] = {
        var map: [String: (String, Double)] = [:]
        map.reserveCapacity(harmonicSpeedMapping.count)
        for (key, speed) in harmonicSpeedMapping {
            map[key.uppercased()] = (key, speed)
        }
        return map
    }()

    /// Convertit un constituant JSON en `TidalConstituent` moteur : résout l'id
    /// canonique + la vitesse (insensible à la casse) et filtre les amplitudes nulles.
    nonisolated private static func makeConstituent(_ c: ConstituentJSON) -> TidalConstituent? {
        guard let match = canonicalConstituent[c.id.uppercased()], c.amplitude > 0.001 else { return nil }
        return TidalConstituent(id: match.id, speed: match.speed, amplitude: c.amplitude, phase: c.phase)
    }

    /// Stations TICON décodées UNE SEULE FOIS (3,7 Mo). `decodeTICON` (ports mondiaux) et
    /// `linkFrenchPorts` (harmoniques FR) le parsaient chacun de leur côté au lancement →
    /// double décodage concurrent. `static let` = init paresseuse thread-safe, partagée.
    nonisolated private static let cachedTICONStations: [TICONStationJSON] = {
        guard let url = Bundle.main.url(forResource: "ticon_stations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stations = try? JSONDecoder().decode([TICONStationJSON].self, from: data) else {
            appLogger.error("[PortCatalog] ticon_stations.json illisible")
            return []
        }
        return stations
    }()

    // MARK: - Structures JSON

    private struct NOAAStationJSON: Decodable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let timezone: String
        let country: String?
        let state: String?
        let meanSeaLevel: Double
        let constituents: [ConstituentJSON]
    }

    private struct TICONStationJSON: Decodable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let timezone: String
        let country: String?
        let continent: String?
        let meanSeaLevel: Double
        let constituents: [ConstituentJSON]
    }

    private struct ConstituentJSON: Decodable {
        let id: String
        let amplitude: Double
        let phase: Double
    }

    /// Constituants TICON → moteur. Les phases TICON sont RÉFÉRENCÉES À GREENWICH
    /// (UTC) : AUCUNE correction de fuseau. Validé par arbitrage indépendant
    /// (extrema Open-Meteo sea_level + retard constant du bassin) : zone 0 → ±10-20 min ;
    /// une correction « heure locale » décalait tout de +1 h (et +9 h au Japon !).
    nonisolated private static func greenwichConstituents(
        _ raw: [ConstituentJSON], timezoneID: String
    ) -> [TidalConstituent] {
        raw.compactMap { makeConstituent($0) }
    }

    // MARK: - API publique

    /// Ports français (SHOM). Léger (≈17 Ko) → chargé de façon synchrone au lancement
    /// pour que l'app soit immédiatement utilisable (le port par défaut est français).
    func loadFrenchPorts() -> [Port] {
        loadSHOM()
    }

    /// Décode les ports mondiaux (NOAA + TICON) **hors du thread principal** puis renvoie
    /// les ports et leurs harmoniques. L'appelant doit ensuite `register(_:)` les
    /// harmoniques et fusionner les ports sur le main actor.
    func loadWorldPortsInBackground() async -> (ports: [Port], harmonics: [PortHarmonics]) {
        await Task.detached(priority: .userInitiated) {
            let noaa = Self.decodeNOAA()
            let ticon = Self.decodeTICON()
            return (noaa.ports + ticon.ports, noaa.harmonics + ticon.harmonics)
        }.value
    }

    /// Enregistre une liste d'harmoniques dans le moteur (main actor).
    func register(_ harmonicsList: [PortHarmonics]) {
        for h in harmonicsList {
            HarmonicTideEngine.shared.registerHarmonics(h)
        }
    }

    /// Rattache chaque port français à la station TICON la plus proche (≤ 80 km) et
    /// fabrique ses harmoniques avec un Z₀ auto-dérivé (≈ zéro hydrographique).
    /// Remplace l'ancienne source SHOM : prédictions 100 % maison, dataset CC-BY 4.0.
    /// Calcul intégral hors du thread principal (décodage JSON + Z₀ ≈ 1-3 s).
    func linkFrenchHarmonicsInBackground(frenchPorts: [Port]) async -> [PortHarmonics] {
        let result = await Task.detached(priority: .userInitiated) {
            Self.linkFrenchPorts(frenchPorts)
        }.value
        frenchLinkDistanceKm = result.distancesKm
        return result.harmonics
    }

    /// Distance port→station TICON (km) du rattachement — sert au recalage fin
    /// Open-Meteo (réservé aux ports rattachés LOIN de leur station).
    private(set) var frenchLinkDistanceKm: [String: Double] = [:]

    /// Niveau moyen au-dessus du ZÉRO HYDROGRAPHIQUE (m), publié par le SHOM (via maree.info,
    /// licence SHOM), pour les ports de référence vérifiés. Sert de Z₀ exact : le Z₀ dérivé
    /// (LAT sur fenêtre 425 j) sous-estime le datum de ~0,1-0,44 m → hauteurs trop basses.
    /// Valeurs confirmées chiffres en main (audit juin 2026). Les autres ports gardent le Z₀ dérivé.
    nonisolated static let publishedFrenchDatum: [String: Double] = [
        "BREST": 4.13,
        "ARCACHON_EYRAC": 2.53,
        "SAINT-MALO": 6.76,
        "LA_ROCHELLE-PALLICE": 3.90,
        "CHERBOURG": 3.81,
        "LE_HAVRE": 4.88,
        "DUNKERQUE": 3.24,
        "SAINT-NAZAIRE": 3.57,
        "ROSCOFF": 5.25,
        "CONCARNEAU": 2.96,
    ]

    /// IDs des ports français situés HORS métropole. La métropole + Corse tient dans une boîte
    /// lat 41–51,6 / lon -5,5–9,8 ; tout port français en dehors est ultramarin (Polynésie,
    /// Nouvelle-Calédonie, Réunion, Antilles, Guyane, Mayotte, St-Pierre…). Sert à n'appliquer le
    /// coefficient national (ancré à Brest) qu'en métropole — il n'a aucun sens outre-mer.
    nonisolated static func overseasFrenchIds(_ ports: [Port]) -> Set<String> {
        Set(ports.filter { p in
            !(p.latitude >= 41.0 && p.latitude <= 51.6 && p.longitude >= -5.5 && p.longitude <= 9.8)
        }.map(\.id))
    }

    nonisolated private static func linkFrenchPorts(_ frenchPorts: [Port]) -> (harmonics: [PortHarmonics], distancesKm: [String: Double]) {
        let stations = cachedTICONStations
        guard !stations.isEmpty else {
            appLogger.error("[PortCatalog] ticon_stations.json illisible pour le rattachement FR")
            return ([], [:])
        }

        // Candidates : TOUTES les stations avec un M2 valide (y compris les françaises,
        // exclues du catalogue de ports mais précieuses ici comme sources d'harmoniques).
        struct Candidate {
            let key: String
            let lat: Double
            let lon: Double
            let constituents: [TidalConstituent]
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(stations.count)
        for s in stations {
            // EXCLURE les marégraphes FLUVIAUX (réseau Vigicrues) : leur marée est AMORTIE en
            // rivière (M2 sous-dimensionné) → ils faisaient lier des ports côtiers à un marnage
            // trop faible (ex. Locquemeau rattaché à Morlaix-Vigicrues : hauteurs ~3,3 m trop
            // basses). Le port se rattache alors à une vraie station côtière voisine.
            if s.id.lowercased().contains("vigicrues") { continue }
            // Phases TICON déjà référencées Greenwich (UTC) → AUCUNE correction de fuseau
            // (cf. greenwichConstituents : une correction « heure locale » décale tout).
            let cs = greenwichConstituents(s.constituents, timezoneID: s.timezone)
            guard cs.contains(where: { $0.id == "M2" }) else { continue }
            candidates.append(Candidate(key: s.id, lat: s.latitude, lon: s.longitude, constituents: cs))
        }
        guard !candidates.isEmpty else { return ([], [:]) }

        let maxKm = 80.0
        var out: [PortHarmonics] = []
        var distances: [String: Double] = [:]
        out.reserveCapacity(frenchPorts.count)

        for port in frenchPorts {
            // Station la plus proche (équirectangulaire, suffisant à ces distances).
            let cosLat = cos(port.latitude * .pi / 180)
            var best: (cand: Candidate, d2: Double)?
            for c in candidates {
                let dLat = (c.lat - port.latitude) * 111.0
                let dLon = (c.lon - port.longitude) * 111.0 * cosLat
                let d2 = dLat * dLat + dLon * dLon
                if best == nil || d2 < best!.d2 { best = (c, d2) }
            }
            // ≤ 80 km exigés en règle générale ; au-delà (atolls isolés des DOM-TOM,
            // station parfois à 300-700 km), on prend quand même la plus proche :
            // mieux vaut une prédiction approchée que pas de données du tout.
            guard let b = best else { continue }
            if b.d2 > maxKm * maxKm {
                appLogger.debug("[PortCatalog] \(port.name) rattaché à \(Int(b.d2.squareRoot())) km (station lointaine)")
            }

            // Z₀ PARESSEUX (même voie que les ports mondiaux, validée par l'audit) :
            //  • datum SHOM publié si connu → instantané ET exact (corrige le biais
            //    LAT-vs-zéro-hydro ~0,1-0,44 m : ex. Brest publié 4,13) ;
            //  • sinon 0 → le vrai Z₀ est dérivé À LA DEMANDE (ensureChartDatumSync) la 1re
            //    fois que CE port est prédit.
            // → on ne dérive plus chartDatumZ0 pour ~119 stations À CHAQUE LANCEMENT
            //   (~10 200 itérations/station = LES >10 s de démarrage). Résultat de prédiction
            //   STRICTEMENT IDENTIQUE (le Z₀ paresseux = le Z₀ eager, fonction déterministe).
            let meanLevel = Self.publishedFrenchDatum[port.id] ?? 0
            out.append(PortHarmonics(id: port.id, meanSeaLevel: meanLevel, constituents: b.cand.constituents))
            distances[port.id] = b.d2.squareRoot()
        }

        appLogger.info("[PortCatalog] Rattachement FR→TICON : \(out.count)/\(frenchPorts.count) ports (Z₀ paresseux)")
        return (out, distances)
    }

    // MARK: - Sources individuelles

    private func loadSHOM() -> [Port] {
        guard let url = Bundle.main.url(forResource: "shom_ports", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            appLogger.error("[PortCatalog] Impossible de charger shom_ports.txt")
            return []
        }

        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line -> Port? in
                let components = line.components(separatedBy: ":")
                guard components.count == 4,
                      let latitude = Double(components[2]),
                      let longitude = Double(components[3]) else {
                    return nil
                }
                return Port(
                    id: components[0],
                    name: components[1],
                    latitude: latitude,
                    longitude: longitude,
                    portTimeZoneIdentifier: Port.frenchTimeZoneIdentifier(latitude: latitude, longitude: longitude),
                    source: .shom,
                    country: "France"
                )
            }
    }

    nonisolated private static func decodeNOAA() -> (ports: [Port], harmonics: [PortHarmonics]) {
        guard let url = Bundle.main.url(forResource: "noaa_stations", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            appLogger.info("[PortCatalog] noaa_stations.json non trouvé")
            return ([], [])
        }

        do {
            let stations = try JSONDecoder().decode([NOAAStationJSON].self, from: data)
            var ports: [Port] = []
            var harmonicsList: [PortHarmonics] = []
            ports.reserveCapacity(stations.count)

            for station in stations {
                let country: String
                if let state = station.state, !state.isEmpty {
                    country = "États-Unis — \(state)"
                } else {
                    country = station.country ?? "États-Unis"
                }

                ports.append(Port(
                    id: station.id,
                    name: station.name,
                    latitude: station.latitude,
                    longitude: station.longitude,
                    portTimeZoneIdentifier: station.timezone,
                    source: .noaa,
                    country: country
                ))

                let tidalConstituents = station.constituents.compactMap { Self.makeConstituent($0) }
                if !tidalConstituents.isEmpty {
                    harmonicsList.append(PortHarmonics(
                        id: station.id,
                        meanSeaLevel: station.meanSeaLevel,   // Z₀ dérivé paresseusement (cf. ensureChartDatum)
                        constituents: tidalConstituents
                    ))
                }
            }

            appLogger.info("[PortCatalog] \(stations.count) ports NOAA décodés")
            return (ports, harmonicsList)
        } catch {
            appLogger.error("[PortCatalog] Erreur NOAA: \(error)")
            return ([], [])
        }
    }

    nonisolated private static func decodeTICON() -> (ports: [Port], harmonics: [PortHarmonics]) {
        let stations = cachedTICONStations   // décodé une seule fois (partagé avec linkFrenchPorts)
        guard !stations.isEmpty else {
            appLogger.info("[PortCatalog] ticon_stations.json non trouvé")
            return ([], [])
        }

        // Pays français à exclure (déjà couverts par SHOM)
        let frenchCountries: Set<String> = [
            "France", "france",
            "French Polynesia", "New Caledonia",
            "Wallis and Futuna", "Saint Pierre and Miquelon",
            "French Southern Territories", "Mayotte",
            "Reunion", "Réunion", "Guadeloupe", "Martinique",
            "French Guiana", "Guyane française",
            "Saint Barthélemy", "Saint Martin",
            "Clipperton Island",
        ]

        func isFrench(_ station: TICONStationJSON) -> Bool {
            if let country = station.country, frenchCountries.contains(country) { return true }
            let lowerID = station.id.lowercased()
            return lowerID.contains("-fra-") || lowerID.contains("-pyf-") || lowerID.contains("-ncl-")
        }

        // Amplitude d'un constituant par id (insensible à la casse).
        func amp(_ cons: [ConstituentJSON], _ id: String) -> Double {
            cons.first(where: { $0.id.uppercased() == id })?.amplitude ?? 0
        }
        // Station « corrompue » : termes saisonniers (SA/SSA) implausibles vs M2 — ex. la
        // station marégraphe « Fenit Opw Station » (M2=1.23 sous-dimensionné + SA=0.38/SSA=0.41)
        // donnait des hauteurs ~1,6 m trop basses. (Ports à micro-marée exemptés : M2 ≤ 0,1.)
        func isSeasonalCorrupt(_ cons: [ConstituentJSON]) -> Bool {
            let m2 = amp(cons, "M2")
            guard m2 > 0.1 else { return false }
            return (amp(cons, "SA") + amp(cons, "SSA")) > 0.3 * m2
        }

        // Candidats mondiaux (français exclus → couverts par SHOM).
        let candidates = stations.filter { !isFrench($0) }
        let skippedFrench = stations.count - candidates.count

        // Index spatial des stations SAINES (grille ~2 km) pour détecter un doublon proche.
        struct GridKey: Hashable { let a: Int; let b: Int }
        func gkey(_ lat: Double, _ lon: Double) -> GridKey { GridKey(a: Int((lat * 50).rounded()), b: Int((lon * 50).rounded())) }
        var healthyGrid: [GridKey: [(lat: Double, lon: Double)]] = [:]
        for s in candidates where !isSeasonalCorrupt(s.constituents) {
            healthyGrid[gkey(s.latitude, s.longitude), default: []].append((s.latitude, s.longitude))
        }
        func hasHealthyNeighbor(_ lat: Double, _ lon: Double) -> Bool {
            let cosLat = cos(lat * .pi / 180)
            for dA in -1...1 { for dB in -1...1 {
                let k = GridKey(a: Int((lat * 50).rounded()) + dA, b: Int((lon * 50).rounded()) + dB)
                for g in healthyGrid[k] ?? [] {
                    let dx = (g.lat - lat) * 111.0, dy = (g.lon - lon) * 111.0 * cosLat
                    if dx * dx + dy * dy < 4.0 { return true }   // < 2 km
                }
            } }
            return false
        }

        var ports: [Port] = []
        var harmonicsList: [PortHarmonics] = []
        ports.reserveCapacity(candidates.count)
        var droppedCorrupt = 0

        for station in candidates {
            // Écarter une station corrompue UNIQUEMENT si une station saine co-localisée existe
            // (sinon on garde : mieux qu'aucune donnée pour la région).
            if isSeasonalCorrupt(station.constituents),
               hasHealthyNeighbor(station.latitude, station.longitude) {
                droppedCorrupt += 1
                continue
            }

            ports.append(Port(
                id: station.id,
                name: station.name,
                latitude: station.latitude,
                longitude: station.longitude,
                portTimeZoneIdentifier: station.timezone,
                source: .ticon,
                country: station.country ?? "Monde"
            ))

            // Phases TICON déjà référencées Greenwich (UTC) → AUCUNE correction de fuseau
            // (cf. greenwichConstituents : une correction « heure locale » décale tout).
            let tidalConstituents = greenwichConstituents(station.constituents, timezoneID: station.timezone)
            if !tidalConstituents.isEmpty {
                harmonicsList.append(PortHarmonics(
                    id: station.id,
                    meanSeaLevel: station.meanSeaLevel,
                    constituents: tidalConstituents
                ))
            }
        }

        appLogger.info("[PortCatalog] \(ports.count) ports TICON décodés (\(skippedFrench) français exclus, \(droppedCorrupt) doublons corrompus écartés)")
        return (ports, harmonicsList)
    }
}
