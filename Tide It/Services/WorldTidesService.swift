//
//  WorldTidesService.swift
//  Tide It
//
//  Service de récupération des marées mondiales via l'API WorldTides.
//  Utilisé pour les ports TICON (hors France/USA) afin d'obtenir
//  des prédictions fiables au lieu des harmoniques offline.
//
//  API : https://www.worldtides.info/api/v3
//  Coût : 1 crédit = 7 jours de prédictions PM/BM
//

import Foundation
import os.log

/// Service dédié à l'API WorldTides pour les marées mondiales
@MainActor
final class WorldTidesService {
    static let shared = WorldTidesService()

    private let baseURL = "https://www.worldtides.info/api/v3"

    /// Clé API : résolue via APIKeys (UserDefaults → Info.plist → fallback)
    var apiKey: String { APIKeys.worldTides }

    /// Toujours configuré grâce à la clé par défaut
    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Erreurs

    enum WorldTidesError: LocalizedError {
        case noAPIKey
        case quotaExhausted
        case invalidResponse(String)
        case noData

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Clé API WorldTides non configurée"
            case .quotaExhausted:
                return "Quota WorldTides épuisé — rechargez vos crédits sur worldtides.info"
            case .invalidResponse(let msg):
                return "Erreur WorldTides : \(msg)"
            case .noData:
                return "Aucune donnée de marée disponible pour cette position"
            }
        }
    }

    // MARK: - Fetch Predictions

    /// Récupère les prédictions PM/BM pour une position géographique sur 7 jours
    /// - Parameters:
    ///   - latitude: Latitude du port
    ///   - longitude: Longitude du port
    /// - Returns: Tableau de TideData triées chronologiquement
    func fetchTidePredictions(latitude: Double, longitude: Double) async throws -> [TideData] {
        guard isConfigured else {
            throw WorldTidesError.noAPIKey
        }

        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "extremes", value: ""),
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
            URLQueryItem(name: "days", value: "7"),
            URLQueryItem(name: "datum", value: "LAT"),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "key", value: apiKey),
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Vérifier le statut HTTP
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WorldTidesError.invalidResponse("Clé API invalide")
            }
            if http.statusCode == 429 {
                throw WorldTidesError.quotaExhausted
            }
            throw URLError(.badServerResponse)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Parse Response

    /// Parse la réponse JSON WorldTides en [TideData]
    /// Format : { "status": 200, "extremes": [{ "dt": 1710000000, "date": "...", "height": 1.23, "type": "High" }] }
    private func parseResponse(data: Data) throws -> [TideData] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorldTidesError.invalidResponse("JSON invalide")
        }

        // Vérifier le statut
        if let status = json["status"] as? Int, status != 200 {
            let error = json["error"] as? String ?? "Erreur inconnue"
            if error.lowercased().contains("credit") || error.lowercased().contains("quota") {
                throw WorldTidesError.quotaExhausted
            }
            throw WorldTidesError.invalidResponse(error)
        }

        guard let extremes = json["extremes"] as? [[String: Any]], !extremes.isEmpty else {
            throw WorldTidesError.noData
        }

        var tides: [TideData] = []

        for extreme in extremes {
            guard let dt = extreme["dt"] as? TimeInterval,
                  let height = extreme["height"] as? Double,
                  let typeStr = extreme["type"] as? String else {
                continue
            }

            let date = Date(timeIntervalSince1970: dt)
            let isHighTide = typeStr == "High"

            tides.append(TideData(
                date: date,
                height: height,
                isHighTide: isHighTide,
                coefficient: nil
            ))
        }

        guard !tides.isEmpty else {
            throw WorldTidesError.noData
        }

        appLogger.info("[WorldTides] \(tides.count) extremes récupérés")
        return tides.sorted { $0.date < $1.date }
    }
}
