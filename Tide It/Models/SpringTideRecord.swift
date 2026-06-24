import Foundation

// MARK: - Modèle d'historique des grandes marées

/// Enregistrement d'un événement de grande marée (coef ≥ 100 ou marnage extrême)
struct SpringTideRecord: Codable, Identifiable, Equatable {
    let id: String
    let portId: String
    let portName: String
    let date: Date
    let coefficient: Int
    let highTideHeight: Double
    let lowTideHeight: Double
    let source: String // "shom", "noaa", "ticon"

    /// Marnage = différence entre pleine mer et basse mer
    var tidalRange: Double {
        highTideHeight - lowTideHeight
    }

    /// Catégorie de la grande marée
    var category: SpringTideCategory {
        switch coefficient {
        case 120...: return .exceptional
        case 110..<120: return .veryStrong
        case 100..<110: return .strong
        default: return .notable
        }
    }

    init(portId: String, portName: String, date: Date, coefficient: Int,
         highTideHeight: Double, lowTideHeight: Double, source: String) {
        self.id = "\(portId)_\(Int(date.timeIntervalSince1970))_\(coefficient)"
        self.portId = portId
        self.portName = portName
        self.date = date
        self.coefficient = coefficient
        self.highTideHeight = highTideHeight
        self.lowTideHeight = lowTideHeight
        self.source = source
    }
}

// MARK: - Catégorie

enum SpringTideCategory: String, Codable, CaseIterable {
    case notable      // coef 90-99
    case strong       // coef 100-109
    case veryStrong   // coef 110-119
    case exceptional  // coef 120+

    var label: String {
        switch self {
        case .notable: return String(localized: "Notable")
        case .strong: return String(localized: "Forte")
        case .veryStrong: return String(localized: "Très forte")
        case .exceptional: return String(localized: "Exceptionnelle")
        }
    }

    var labelEN: String {
        switch self {
        case .notable: return "Notable"
        case .strong: return "Strong"
        case .veryStrong: return "Very strong"
        case .exceptional: return "Exceptional"
        }
    }

    var minCoefficient: Int {
        switch self {
        case .notable: return 90
        case .strong: return 100
        case .veryStrong: return 110
        case .exceptional: return 120
        }
    }
}

// MARK: - Statistiques

struct SpringTideStats {
    let totalCount: Int
    let maxCoefficient: Int
    let maxTidalRange: Double
    let averageCoefficient: Double
    let byCategory: [SpringTideCategory: Int]
    let mostFrequentPort: String?

    static let empty = SpringTideStats(
        totalCount: 0, maxCoefficient: 0, maxTidalRange: 0,
        averageCoefficient: 0, byCategory: [:], mostFrequentPort: nil
    )
}
