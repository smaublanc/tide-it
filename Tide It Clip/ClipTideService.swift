import Foundation
import SwiftUI
import os

/// Service léger pour l'App Clip — récupère les marées d'un port via SHOM ou NOAA
@MainActor
final class ClipTideService: ObservableObject {
    @Published var portName: String = ""
    @Published var portId: String = ""
    @Published var tideData: [ClipTideData] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(subsystem: "com.seb.TideIt.Clip", category: "service")

    struct ClipTideData: Identifiable {
        let id = UUID()
        let date: Date
        let height: Double
        let isHighTide: Bool
        let coefficient: Int?
    }

    // MARK: - URL Handling

    /// Format attendu: https://tideit.app/port/{portId}?name={portName}&source={shom|noaa}
    func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let pathParts = components.path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0] == "port" else { return }

        let id = String(pathParts[1])
        let name = components.queryItems?.first(where: { $0.name == "name" })?.value ?? id
        let source = components.queryItems?.first(where: { $0.name == "source" })?.value ?? "shom"

        self.portId = id
        self.portName = name

        Task {
            await fetchTides(portId: id, source: source)
        }
    }

    /// Chargement direct pour preview/debug
    func loadPort(id: String, name: String, source: String = "shom") {
        self.portId = id
        self.portName = name
        Task {
            await fetchTides(portId: id, source: source)
        }
    }

    // MARK: - Fetch

    private func fetchTides(portId: String, source: String) async {
        isLoading = true
        errorMessage = nil

        do {
            switch source {
            case "noaa":
                tideData = try await fetchNOAATides(stationId: portId)
            default:
                tideData = try await fetchSHOMTides(portId: portId)
            }
        } catch {
            logger.error("Erreur fetch: \(error.localizedDescription)")
            errorMessage = "Impossible de charger les marées"
        }

        isLoading = false
    }

    // MARK: - SHOM

    private func fetchSHOMTides(portId: String) async throws -> [ClipTideData] {
        let baseURL = "https://services.data.shom.fr/hdm/vignette/grande/"
        guard let url = URL(string: "\(baseURL)\(portId)") else {
            throw URLError(.badURL)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        let (data, _) = try await session.data(from: url)

        struct SHOMResponse: Decodable {
            let date: String
            let hauteur: Double
            let type: String
            let coef: Int?

            private enum CodingKeys: String, CodingKey {
                case date, hauteur, type, coef
            }
        }

        let decoder = JSONDecoder()
        let items = try decoder.decode([SHOMResponse].self, from: data)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

        return items.compactMap { item in
            guard let date = formatter.date(from: item.date) else { return nil }
            return ClipTideData(
                date: date,
                height: item.hauteur,
                isHighTide: item.type == "PM",
                coefficient: item.coef
            )
        }
    }

    // MARK: - NOAA

    private func fetchNOAATides(stationId: String) async throws -> [ClipTideData] {
        let cleanId = stationId.replacingOccurrences(of: "NOAA_", with: "")
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10).replacingOccurrences(of: "-", with: "")
        let tomorrow = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400 * 2)).prefix(10).replacingOccurrences(of: "-", with: "")

        let urlString = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&datum=LAT&station=\(cleanId)&begin_date=\(today)&end_date=\(tomorrow)&interval=hilo&units=metric&time_zone=gmt&format=json"

        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(from: url)

        struct NOAAResponse: Decodable {
            let predictions: [NOAAPrediction]
        }
        struct NOAAPrediction: Decodable {
            let t: String
            let v: String
            let type: String
        }

        let response = try JSONDecoder().decode(NOAAResponse.self, from: data)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "GMT")

        return response.predictions.compactMap { pred in
            guard let date = formatter.date(from: pred.t),
                  let height = Double(pred.v) else { return nil }
            return ClipTideData(
                date: date,
                height: height,
                isHighTide: pred.type == "H",
                coefficient: nil
            )
        }
    }
}
