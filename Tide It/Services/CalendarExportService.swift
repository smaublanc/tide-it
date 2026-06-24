//
//  CalendarExportService.swift
//  Tide It
//
//  Export des marées vers le calendrier iOS (EventKit)
//

import EventKit
import Foundation
import os.log

class CalendarExportService {
    static let shared = CalendarExportService()

    private let eventStore = EKEventStore()

    /// Vérifie et demande l'accès au calendrier
    func requestAccess() async -> Bool {
        do {
            // Write-only : l'app ÉCRIT des événements de marée, ne LIT jamais le calendrier
            // (scope minimal — guideline 5.1.1). Clé Info.plist : NSCalendarsWriteOnlyAccessUsageDescription.
            return try await eventStore.requestWriteOnlyAccessToEvents()
        } catch {
            appLogger.error("Erreur accès calendrier: \(error)")
            return false
        }
    }

    /// Exporte les marées d'un jour dans le calendrier
    func exportTides(
        tideData: [TideData],
        portName: String,
        date: Date,
        portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    ) async -> Result<Int, CalendarExportError> {
        // Vérifier l'accès
        let granted = await requestAccess()
        guard granted else {
            return .failure(.accessDenied)
        }

        let calendar = Calendar.inTimeZone(portTimeZone)
        let dayTides = tideData.filter { calendar.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date < $1.date }

        guard !dayTides.isEmpty else {
            return .failure(.noData)
        }

        var addedCount = 0

        for tide in dayTides {
            let event = EKEvent(eventStore: eventStore)
            let type = tide.isHighTide ? "PM" : "BM"
            let height = SharedUnitFormatter.height(tide.height, decimals: 2)
            let coef = tide.coefficient.map { " - Coef \($0)" } ?? ""

            event.title = "🌊 \(type) \(portName) - \(height)\(coef)"
            event.startDate = tide.date
            event.endDate = tide.date.addingTimeInterval(900) // 15 min
            event.timeZone = portTimeZone
            event.calendar = eventStore.defaultCalendarForNewEvents
            event.notes = "Marée \(tide.isHighTide ? "haute" : "basse") à \(portName)\nHauteur: \(height)\(coef)\n\nAjouté par Tide It"

            // Alerte 30 minutes avant
            event.addAlarm(EKAlarm(relativeOffset: -1800))

            do {
                try eventStore.save(event, span: .thisEvent)
                addedCount += 1
            } catch {
                appLogger.error("Erreur ajout événement: \(error)")
            }
        }

        if addedCount > 0 {
            return .success(addedCount)
        } else {
            return .failure(.saveFailed)
        }
    }

    /// Exporte toutes les marées disponibles dans le calendrier
    func exportAllTides(
        tideData: [TideData],
        portName: String
    ) async -> Result<Int, CalendarExportError> {
        let granted = await requestAccess()
        guard granted else {
            return .failure(.accessDenied)
        }

        guard !tideData.isEmpty else {
            return .failure(.noData)
        }

        var addedCount = 0
        let sortedTides = tideData.sorted { $0.date < $1.date }

        for tide in sortedTides {
            let event = EKEvent(eventStore: eventStore)
            let type = tide.isHighTide ? "PM" : "BM"
            let height = SharedUnitFormatter.height(tide.height, decimals: 2)
            let coef = tide.coefficient.map { " - Coef \($0)" } ?? ""

            event.title = "🌊 \(type) \(portName) - \(height)\(coef)"
            event.startDate = tide.date
            event.endDate = tide.date.addingTimeInterval(900)
            event.calendar = eventStore.defaultCalendarForNewEvents
            event.notes = "Ajouté par Tide It"

            event.addAlarm(EKAlarm(relativeOffset: -1800))

            do {
                try eventStore.save(event, span: .thisEvent)
                addedCount += 1
            } catch {
                appLogger.error("Erreur ajout événement: \(error)")
            }
        }

        return addedCount > 0 ? .success(addedCount) : .failure(.saveFailed)
    }

    enum CalendarExportError: LocalizedError {
        case accessDenied
        case noData
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Accès au calendrier refusé. Vérifiez les réglages."
            case .noData: return "Aucune donnée de marée à exporter."
            case .saveFailed: return "Impossible de sauvegarder les événements."
            }
        }
    }
}
