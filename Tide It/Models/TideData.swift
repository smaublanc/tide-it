import Foundation

struct TideData: Codable, Identifiable, Equatable {
    let date: Date
    let height: Double
    let isHighTide: Bool
    let coefficient: Int?

    var id: String {
        "\(Int(date.timeIntervalSince1970))_\(isHighTide ? "H" : "L")_\(String(format: "%.2f", height))"
    }

    enum CodingKeys: String, CodingKey {
        case date
        case height = "hauteur"
        case coefficient = "coef"
        case isHighTide
    }

    static func == (lhs: TideData, rhs: TideData) -> Bool {
        return lhs.date == rhs.date &&
               lhs.height == rhs.height &&
               lhs.isHighTide == rhs.isHighTide &&
               lhs.coefficient == rhs.coefficient
    }
    
    /// Génère des marées factices pour les tests
    /// - Parameters:
    ///   - date: Date centrale pour les marées
    ///   - daysBeforeAfter: Nombre de jours avant/après à générer
    /// - Returns: Un tableau de données de marées
    static func generateMockTides(for date: Date, daysBeforeAfter: Int = 1) -> [TideData] {
        var mockTides: [TideData] = []
        let calendar = Calendar.current
        
        // Définir la plage de dates: jours précédents, jour actuel et jours suivants
        guard let startDate = calendar.date(byAdding: .day, value: -daysBeforeAfter, to: date),
              let endDate = calendar.date(byAdding: .day, value: daysBeforeAfter, to: date) else {
            return []
        }
        
        // Valeurs réalistes
        let lowTideHeights = (0.3...1.2)
        let highTideHeights = (4.0...7.0)
        let coefficientRange = (40...120)
        
        // Heures typiques des marées
        let tideHours = [
            false: [3, 15],  // Marées basses: 3h et 15h
            true: [9, 21]    // Marées hautes: 9h et 21h
        ]
        
        // Générer des dates pour l'intervalle
        var currentDate = startDate
        while currentDate <= endDate {
            // Pour chaque jour, générer 4 marées (2 hautes, 2 basses)
            for isHighTide in [false, true] {
                for hourIndex in 0..<2 {
                    guard let hours = tideHours[isHighTide], hourIndex < hours.count else { continue }
                    let hour = hours[hourIndex]
                    let minute = Int.random(in: 0...59)
                    
                    let components = DateComponents(
                        year: calendar.component(.year, from: currentDate),
                        month: calendar.component(.month, from: currentDate),
                        day: calendar.component(.day, from: currentDate),
                        hour: hour,
                        minute: minute
                    )
                    
                    if let tideTime = calendar.date(from: components) {
                        // Le coefficient n'est pertinent que pour les marées hautes
                        let coef = isHighTide ? Int.random(in: coefficientRange) : nil
                        
                        let heightRange = isHighTide ? highTideHeights : lowTideHeights
                        
                        mockTides.append(TideData(
                            date: tideTime,
                            height: Double.random(in: heightRange),
                            isHighTide: isHighTide,
                            coefficient: coef
                        ))
                    }
                }
            }
            
            // Passer au jour suivant
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDay
        }
        
        return mockTides.sorted { $0.date < $1.date }
    }
}

struct TideResponse: Codable {
    let data: [TideData]
} 