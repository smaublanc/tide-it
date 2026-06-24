//
//  TideCheckService.swift
//  Tide It
//
//  Service pour l'API TideCheck — 6 470 stations, 176 pays
//  Free tier: 50 req/jour, datum LAT/MLLW/MSL, extremes + timeSeries
//  https://tidecheck.com/developers
//

import Foundation
import os.log

final class TideCheckService {
    static let shared = TideCheckService()

    private let baseURL = "https://tidecheck.com/api"
    private let session: URLSession

    /// Clé API : résolue via APIKeys (UserDefaults → Info.plist → fallback obfusqué)
    private var apiKey: String { APIKeys.tideCheck }

    /// Service de secours désactivé proprement si aucune clé (évite des requêtes vouées à échouer).
    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Cache des stations les plus proches (évite de refaire nearest à chaque fois)
    private var nearestStationCache: [String: String] = [:] // portId -> tideCheckStationId
    private let cacheLock = NSLock()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Errors

    enum TideCheckError: LocalizedError {
        case notConfigured
        case noStationFound
        case rateLimitExceeded
        case invalidResponse(Int)
        case invalidURL
        case noData
        case decodingError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:       return "Clé API TideCheck non configurée"
            case .noStationFound:      return "Aucune station TideCheck trouvée"
            case .rateLimitExceeded:   return "Limite TideCheck atteinte (50/jour)"
            case .invalidResponse(let code): return "Erreur TideCheck: HTTP \(code)"
            case .invalidURL:          return "URL TideCheck invalide"
            case .noData:              return "Aucune donnée de marée TideCheck"
            case .decodingError(let msg):    return "Erreur décodage TideCheck: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Récupère les marées pour un port via ses coordonnées GPS
    /// 1. Trouve la station la plus proche (nearest)
    /// 2. Récupère les prédictions (tides)
    func fetchTidePredictions(
        latitude: Double,
        longitude: Double,
        portId: String? = nil,
        days: Int = 7,
        datum: String = "LAT"
    ) async throws -> [TideData] {
        guard isConfigured else { throw TideCheckError.notConfigured }

        // Vérifier le cache de station
        let stationId: String
        if let cached = cachedStation(for: portId) {
            stationId = cached
        } else {
            stationId = try await findNearestStation(latitude: latitude, longitude: longitude)
            if let portId {
                cacheStation(stationId, for: portId)
            }
        }

        return try await fetchTides(stationId: stationId, days: days, datum: datum)
    }

    /// Recherche de stations par nom
    func searchStations(query: String) async throws -> [TideCheckStation] {
        guard isConfigured else { throw TideCheckError.notConfigured }

        var components = URLComponents(string: "\(baseURL)/stations/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw TideCheckError.invalidURL }

        let data = try await performRequest(url: url)
        return try JSONDecoder().decode([TideCheckStation].self, from: data)
    }

    // MARK: - Private

    /// Trouve la station la plus proche par coordonnées
    private func findNearestStation(latitude: Double, longitude: Double) async throws -> String {
        var components = URLComponents(string: "\(baseURL)/stations/nearest")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude))
        ]
        guard let url = components?.url else { throw TideCheckError.invalidURL }

        let data = try await performRequest(url: url)
        let stations = try JSONDecoder().decode([TideCheckNearestStation].self, from: data)

        guard let nearest = stations.first else {
            throw TideCheckError.noStationFound
        }

        appLogger.info("[TideCheck] Station la plus proche: \(nearest.name) (\(nearest.id)) à \(nearest.distanceKm, format: .fixed(precision: 1))km")
        return nearest.id
    }

    /// Récupère les prédictions de marée pour une station
    private func fetchTides(stationId: String, days: Int, datum: String) async throws -> [TideData] {
        var components = URLComponents(string: "\(baseURL)/station/\(stationId)/tides")
        components?.queryItems = [
            URLQueryItem(name: "datum", value: datum),
            URLQueryItem(name: "days", value: String(days))
        ]
        guard let url = components?.url else { throw TideCheckError.invalidURL }

        let data = try await performRequest(url: url)

        // Décoder la réponse
        let response: TideCheckResponse
        do {
            response = try JSONDecoder().decode(TideCheckResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "N/A"
            appLogger.error("[TideCheck] Erreur décodage: \(error.localizedDescription) — raw: \(raw.prefix(200))")
            throw TideCheckError.decodingError(error.localizedDescription)
        }

        guard !response.extremes.isEmpty else {
            throw TideCheckError.noData
        }

        // Convertir en TideData
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        let tides: [TideData] = response.extremes.compactMap { extreme in
            guard let date = iso.date(from: extreme.time) ?? isoFallback.date(from: extreme.time) else {
                appLogger.warning("[TideCheck] Date invalide: \(extreme.time)")
                return nil
            }

            let isHigh = extreme.type.lowercased() == "high"
            return TideData(
                date: date,
                height: extreme.height,
                isHighTide: isHigh,
                coefficient: nil
            )
        }

        appLogger.info("[TideCheck] \(tides.count) marées récupérées pour station \(stationId) (\(response.station.name))")
        return tides
    }

    /// Effectue une requête HTTP avec la clé API
    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TideCheckError.invalidResponse(0)
        }

        // Log des rate limits
        if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining") {
            appLogger.debug("[TideCheck] Rate limit restant: \(remaining)")
        }

        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw TideCheckError.notConfigured
        case 429:
            appLogger.warning("[TideCheck] Rate limit atteint!")
            throw TideCheckError.rateLimitExceeded
        default:
            throw TideCheckError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - Station Cache

    private func cachedStation(for portId: String?) -> String? {
        guard let portId else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return nearestStationCache[portId]
    }

    private func cacheStation(_ stationId: String, for portId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        nearestStationCache[portId] = stationId
    }
}

// MARK: - API Response Models

struct TideCheckStation: Decodable {
    let id: String
    let slug: String?
    let name: String
    let region: String?
    let country: String?
    let label: String?
}

struct TideCheckNearestStation: Decodable {
    let id: String
    let slug: String?
    let name: String
    let region: String?
    let country: String?
    let lat: Double
    let lng: Double
    let label: String?
    let distanceKm: Double
}

struct TideCheckExtreme: Decodable {
    let time: String
    let localDate: String?
    let height: Double
    let type: String // "high" or "low"
}

struct TideCheckResponse: Decodable {
    let station: TideCheckStationInfo
    let datum: String
    let extremes: [TideCheckExtreme]

    struct TideCheckStationInfo: Decodable {
        let id: String
        let name: String
        let region: String?
        let country: String?
        let lat: Double?
        let lng: Double?
        let timezone: String?
    }
}
