//
//  TideRepository.swift
//  Tide It
//
//  Couche repository : toute la logique de fetching réseau + parsing.
//  Pas d'état @Published, pas de dépendance à TideService.
//  TideService appelle ce repository et gère la publication d'état / le cache.
//
//  Sources dans l'ordre de fallback :
//    - France (.shom) : HarmonicTideEngine (constituants TICON, 100 % offline)
//    - NOAA API (ports .noaa)
//    - TideCheck (fallback NOAA subordinate + TICON)
//    - WorldTides (fallback TICON)
//    - HarmonicTideEngine (offline)
//

import Foundation
import os.log

@MainActor
final class TideRepository {
    static let shared = TideRepository()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - Entrée principale

    /// Récupère les marées pour un port selon sa source. Le `port` est nécessaire
    /// pour les fallbacks NOAA/TICON qui ont besoin des coordonnées.
    func fetchTideData(portId: String, source: PortSource, port: Port?) async throws -> [TideData] {
        switch source {
        case .shom:
            // Ports français : prédiction harmonique MAISON (constituants TICON
            // rattachés au lancement). Plus aucun appel réseau vers le SHOM.
            let tides = fetchFromHarmonics(portId: portId)
            guard !tides.isEmpty else { throw URLError(.resourceUnavailable) }
            return tides

        case .noaa:
            // Prédiction harmonique MAISON en PRIORITÉ (offline) → la fenêtre proche J0-J7 et
            // les prévisions étendues J8-J30 viennent de LA MÊME source : plus de jonction
            // brutale (l'API NOAA donnait un datum MLLW + des horaires différents du moteur).
            // Le réseau (NOAA → TideCheck → WorldTides) ne sert plus que de SECOURS si les
            // constituants harmoniques manquent.
            let harmonicNOAA = fetchFromHarmonics(portId: portId)
            if !harmonicNOAA.isEmpty { return harmonicNOAA }
            do {
                return try await NOAAService.shared.fetchTidePredictions(stationId: portId)
            } catch {
                if let port {
                    if TideCheckService.shared.isConfigured {
                        do {
                            let tides = try await TideCheckService.shared.fetchTidePredictions(
                                latitude: port.latitude, longitude: port.longitude,
                                portId: portId, datum: "MLLW"
                            )
                            appLogger.info("[TideRepository] NOAA fallback TideCheck OK pour \(port.name): \(tides.count) extremes")
                            return tides
                        } catch {
                            appLogger.warning("[TideRepository] NOAA + TideCheck échoués pour \(port.name)")
                        }
                    }
                    if WorldTidesService.shared.isConfigured {
                        do {
                            let tides = try await WorldTidesService.shared.fetchTidePredictions(
                                latitude: port.latitude, longitude: port.longitude
                            )
                            appLogger.info("[TideRepository] NOAA fallback WorldTides OK pour \(port.name): \(tides.count) extremes")
                            return tides
                        } catch {
                            appLogger.warning("[TideRepository] NOAA + WorldTides échoués pour \(port.name)")
                        }
                    }
                }
                // Dernier recours : harmoniques offline
                let harmonicFallback = fetchFromHarmonics(portId: portId)
                if !harmonicFallback.isEmpty { return harmonicFallback }
                throw error
            }

        case .ticon:
            // Idem : harmonique maison d'abord (continu avec l'étendu), APIs en secours.
            let harmonicTICON = fetchFromHarmonics(portId: portId)
            if !harmonicTICON.isEmpty { return harmonicTICON }
            return try await fetchFromTICON(portId: portId, port: port)
        }
    }

    // MARK: - Sources individuelles

    /// Fetch depuis les APIs mondiales pour les ports TICON.
    /// Chaîne : TideCheck (50/j free) → WorldTides → Harmoniques offline.
    func fetchFromTICON(portId: String, port: Port?) async throws -> [TideData] {
        guard let port else {
            appLogger.warning("[TideRepository] Port TICON introuvable: \(portId)")
            return fetchFromHarmonics(portId: portId)
        }

        if TideCheckService.shared.isConfigured {
            do {
                let tides = try await TideCheckService.shared.fetchTidePredictions(
                    latitude: port.latitude,
                    longitude: port.longitude,
                    portId: portId
                )
                appLogger.info("[TideRepository] TideCheck OK pour \(port.name): \(tides.count) extremes")
                return tides
            } catch {
                appLogger.warning("[TideRepository] TideCheck échoué pour \(port.name): \(error.localizedDescription)")
            }
        }

        if WorldTidesService.shared.isConfigured {
            do {
                let tides = try await WorldTidesService.shared.fetchTidePredictions(
                    latitude: port.latitude,
                    longitude: port.longitude
                )
                appLogger.info("[TideRepository] WorldTides OK pour \(port.name): \(tides.count) extremes")
                return tides
            } catch {
                appLogger.warning("[TideRepository] WorldTides échoué pour \(port.name): \(error.localizedDescription)")
            }
        }

        return fetchFromHarmonics(portId: portId)
    }

    /// Génère les prédictions via le moteur harmonique (offline)
    func fetchFromHarmonics(portId: String) -> [TideData] {
        let engine = HarmonicTideEngine.shared
        guard engine.hasHarmonics(for: portId) else {
            appLogger.warning("[TideRepository] Pas de constantes harmoniques pour \(portId)")
            return []
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }

        return engine.predictTides(from: today, to: endDate, portId: portId)
    }

}
