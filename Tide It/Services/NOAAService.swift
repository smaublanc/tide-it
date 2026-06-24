//
//  NOAAService.swift
//  Tide It
//
//  Service de récupération de données de marées depuis l'API NOAA CO-OPS.
//  API gratuite, sans clé, couvrant ~3000 stations aux États-Unis.
//
//  Documentation : https://api.tidesandcurrents.noaa.gov/api/prod/
//

import Foundation
import os.log

/// Service dédié aux stations NOAA (USA)
/// Récupère les prédictions hilo (pleines mers / basses mers) en JSON
@MainActor
class NOAAService {
    static let shared = NOAAService()

    private let baseURL = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Fetch Tide Predictions (hilo)

    /// Récupère les prédictions PM/BM pour un port NOAA sur 7 jours
    /// - Parameter stationId: ID NOAA brut (ex: "9414290"), sans le préfixe "NOAA_"
    /// - Returns: Tableau de TideData triées chronologiquement
    func fetchTidePredictions(stationId: String) async throws -> [TideData] {
        let rawId = stationId.replacingOccurrences(of: "NOAA_", with: "")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let today = Date()
        let beginDate = formatter.string(from: today)
        guard let endRaw = Calendar.current.date(byAdding: .day, value: 7, to: today) else {
            throw URLError(.badURL)
        }
        let endDate = formatter.string(from: endRaw)

        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "begin_date", value: beginDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "station", value: rawId),
            URLQueryItem(name: "product", value: "predictions"),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "interval", value: "hilo"),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "application", value: "TideIt"),
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try parseNOAAResponse(data: data)
    }

    // MARK: - Parse NOAA JSON

    /// Parse la réponse JSON NOAA en [TideData]
    /// Format NOAA : { "predictions": [{ "t": "2026-03-19 05:24", "v": "1.234", "type": "H" }, ...] }
    private func parseNOAAResponse(data: Data) throws -> [TideData] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let predictions = json?["predictions"] as? [[String: Any]] else {
            // Vérifier si c'est une erreur NOAA
            if let errorMsg = json?["error"] as? [String: Any],
               let message = errorMsg["message"] as? String {
                appLogger.error("[NOAAService] Erreur API: \(message)")
            }
            throw URLError(.cannotDecodeContentData)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        var tides: [TideData] = []

        for pred in predictions {
            guard let timeStr = pred["t"] as? String,
                  let valueStr = pred["v"] as? String,
                  let typeStr = pred["type"] as? String,
                  let date = dateFormatter.date(from: timeStr),
                  let height = Double(valueStr) else {
                continue
            }

            let isHighTide = typeStr == "H"

            // NOAA ne fournit pas de coefficient — on le calcule approximativement
            // Le coefficient est un concept français (20-120), on l'estime via le marnage
            let coefficient: Int? = nil

            tides.append(TideData(
                date: date,
                height: height,
                isHighTide: isHighTide,
                coefficient: coefficient
            ))
        }

        return tides.sorted { $0.date < $1.date }
    }

    // MARK: - Fetch Harmonic Constituents

    /// Récupère les constantes harmoniques d'une station NOAA
    /// Utilisé pour alimenter le HarmonicTideEngine pour les prédictions offline/étendues
    func fetchHarmonicConstituents(stationId: String) async throws -> PortHarmonics {
        let rawId = stationId.replacingOccurrences(of: "NOAA_", with: "")

        let urlString = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/\(rawId)/harcon.json?units=metric"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try parseHarmonicConstituents(data: data, portId: stationId)
    }

    /// Parse les constantes harmoniques NOAA en PortHarmonics
    private func parseHarmonicConstituents(data: Data, portId: String) throws -> PortHarmonics {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let harcons = json?["HarmonicConstituents"] as? [[String: Any]] else {
            throw URLError(.cannotDecodeContentData)
        }

        // Mapping des noms NOAA vers nos noms internes
        let nameMapping: [String: String] = [
            "M2": "M2", "S2": "S2", "N2": "N2", "K2": "K2",
            "K1": "K1", "O1": "O1", "P1": "P1", "Q1": "Q1",
            "J1": "J1", "OO1": "OO1",
            "M4": "M4", "MS4": "MS4", "MN4": "MN4", "M6": "M6",
            "2N2": "2N2", "MU2": "MU2", "NU2": "NU2", "L2": "L2",
            "T2": "T2", "LDA2": "LAM2", "LAMBDA2": "LAM2",
            "2MS6": "2MS6",
            "MF": "Mf", "MM": "Mm", "SSA": "Ssa", "SA": "Sa", "MSF": "MSf",
        ]

        // Vitesses angulaires correspondantes
        let speedMapping: [String: Double] = [
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

        var constituents: [TidalConstituent] = []
        var meanSeaLevel: Double = 0

        for hc in harcons {
            guard let name = hc["name"] as? String else { continue }

            // Z0 = niveau moyen
            if name == "Z0" {
                if let amp = hc["amplitude"] as? Double {
                    meanSeaLevel = amp
                }
                continue
            }

            let upperName = name.uppercased()
            guard let internalName = nameMapping[upperName] ?? nameMapping[name],
                  let speed = speedMapping[internalName] else {
                continue
            }

            // Amplitude et phase — NOAA fournit amplitude en mètres et phase_GMT en degrés
            let amplitude: Double
            if let amp = hc["amplitude"] as? Double {
                amplitude = amp
            } else if let ampStr = hc["amplitude"] as? String, let amp = Double(ampStr) {
                amplitude = amp
            } else {
                continue
            }

            let phase: Double
            if let ph = hc["phase_GMT"] as? Double {
                phase = ph
            } else if let phStr = hc["phase_GMT"] as? String, let ph = Double(phStr) {
                phase = ph
            } else {
                continue
            }

            // Ignorer les constituants avec amplitude négligeable
            guard amplitude > 0.001 else { continue }

            constituents.append(TidalConstituent(
                id: internalName,
                speed: speed,
                amplitude: amplitude,
                phase: phase
            ))
        }

        return PortHarmonics(
            id: portId,
            meanSeaLevel: meanSeaLevel,
            constituents: constituents
        )
    }
}
