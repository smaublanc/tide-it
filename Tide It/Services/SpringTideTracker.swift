import Foundation
import os

// MARK: - Service de suivi des grandes marées

@MainActor
final class SpringTideTracker: ObservableObject {
    static let shared = SpringTideTracker()

    @Published private(set) var records: [SpringTideRecord] = []

    private let storageKey = "springTideRecords"
    private let userDefaults: UserDefaults

    /// Seuil minimum de coefficient pour tracker (90 = vives-eaux significatives)
    private let minimumCoefficient = 90

    init() {
        if let shared = UserDefaults(suiteName: WidgetSharedKeys.appGroupId) {
            self.userDefaults = shared
        } else {
            self.userDefaults = .standard
        }
        loadRecords()
    }

    // MARK: - Public API

    /// Analyse les données de marée et enregistre les grandes marées
    func trackSpringTides(from tideData: [TideData], portId: String, portName: String, source: String) {
        let highTides = tideData.filter { $0.isHighTide && ($0.coefficient ?? 0) >= minimumCoefficient }

        var newRecords: [SpringTideRecord] = []

        for highTide in highTides {
            guard let coef = highTide.coefficient else { continue }

            // Trouver la basse mer la plus proche (avant ou après)
            let nearestLow = findNearestLowTide(to: highTide, in: tideData)
            let lowHeight = nearestLow?.height ?? 0

            let record = SpringTideRecord(
                portId: portId,
                portName: portName,
                date: highTide.date,
                coefficient: coef,
                highTideHeight: highTide.height,
                lowTideHeight: lowHeight,
                source: source
            )

            // Éviter les doublons
            if !records.contains(where: { $0.id == record.id }) &&
               !newRecords.contains(where: { $0.id == record.id }) {
                newRecords.append(record)
            }
        }

        if !newRecords.isEmpty {
            records.append(contentsOf: newRecords)
            records.sort { $0.date > $1.date }

            // Limiter à 500 enregistrements max
            if records.count > 500 {
                records = Array(records.prefix(500))
            }

            saveRecords()
            appLogger.info("SpringTideTracker: \(newRecords.count) nouvelles grandes marées enregistrées pour \(portName)")
        }
    }

    /// Statistiques globales
    var stats: SpringTideStats {
        guard !records.isEmpty else { return .empty }

        let coefficients = records.map(\.coefficient)
        let maxCoef = coefficients.max() ?? 0
        let avgCoef = Double(coefficients.reduce(0, +)) / Double(coefficients.count)
        let maxRange = records.map(\.tidalRange).max() ?? 0

        var byCategory: [SpringTideCategory: Int] = [:]
        for record in records {
            byCategory[record.category, default: 0] += 1
        }

        // Port le plus fréquent
        var portCounts: [String: Int] = [:]
        for record in records {
            portCounts[record.portName, default: 0] += 1
        }
        let topPort = portCounts.max(by: { $0.value < $1.value })?.key

        return SpringTideStats(
            totalCount: records.count,
            maxCoefficient: maxCoef,
            maxTidalRange: maxRange,
            averageCoefficient: avgCoef,
            byCategory: byCategory,
            mostFrequentPort: topPort
        )
    }

    /// Records filtrés par port
    func records(for portId: String) -> [SpringTideRecord] {
        records.filter { $0.portId == portId }
    }

    /// Records filtrés par catégorie
    func records(for category: SpringTideCategory) -> [SpringTideRecord] {
        records.filter { $0.category == category }
    }

    /// Supprimer tous les records
    func clearAll() {
        records.removeAll()
        saveRecords()
    }

    // MARK: - Private

    private func findNearestLowTide(to highTide: TideData, in tideData: [TideData]) -> TideData? {
        tideData
            .filter { !$0.isHighTide }
            .min(by: { abs($0.date.timeIntervalSince(highTide.date)) < abs($1.date.timeIntervalSince(highTide.date)) })
    }

    private func loadRecords() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        do {
            records = try JSONDecoder().decode([SpringTideRecord].self, from: data)
            records.sort { $0.date > $1.date }
        } catch {
            appLogger.error("SpringTideTracker: erreur chargement: \(error.localizedDescription)")
        }
    }

    private func saveRecords() {
        do {
            let data = try JSONEncoder().encode(records)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            appLogger.error("SpringTideTracker: erreur sauvegarde: \(error.localizedDescription)")
        }
    }
}
