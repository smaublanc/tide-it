import Foundation

// Extension pour obtenir la fin de la journée
extension Calendar {
    func endOfDay(for date: Date) -> Date {
        let components = DateComponents(day: 1)
        guard let nextDay = self.date(byAdding: components, to: date) else {
            return date.addingTimeInterval(86400)
        }
        let startOfNextDay = self.startOfDay(for: nextDay)
        return self.date(byAdding: .second, value: -1, to: startOfNextDay) ?? date.addingTimeInterval(86399)
    }
} 