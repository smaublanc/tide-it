//
//  DateExtensions.swift
//  Tide It
//
//  Extensions utilitaires pour Date
//

import Foundation

extension Date {
    
    // MARK: - Formatters (cache statique pour performance)
    
    private static let frenchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter
    }()
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEE d"
        return formatter
    }()
    
    // MARK: - Formatted Strings
    
    var frenchDateString: String {
        Self.frenchDateFormatter.string(from: self).capitalized
    }
    
    var timeString: String {
        Self.timeFormatter.string(from: self)
    }
    
    var shortDateString: String {
        Self.shortDateFormatter.string(from: self).capitalized
    }
    
    // MARK: - Day Calculations
    
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }
    
    var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }
    
    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }
    
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }
    
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(self)
    }
    
    var isTomorrow: Bool {
        Calendar.current.isDateInTomorrow(self)
    }
    
    func daysDifference(from other: Date) -> Int {
        Calendar.current.dateComponents([.day], from: other.startOfDay, to: self.startOfDay).day ?? 0
    }
    
    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    func adding(hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: self) ?? self
    }
    
    // MARK: - Progress in Day
    
    var progressInDay: Double {
        let start = startOfDay
        let elapsed = timeIntervalSince(start)
        return elapsed / 86400.0
    }
}
