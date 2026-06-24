//
//  ExportButton.swift
//  Tide It
//
//  Menu de partage/export avec options carte image, PDF, texte, calendrier
//

import SwiftUI
import WeatherKit

struct ExportButton: View {
    let portName: String
    let tideData: [TideData]

    // Données enrichies pour la carte de marée (optionnelles)
    var tideState: TideCalculator.TideState?
    var currentWeather: CurrentWeather?
    var marineConditions: MarineConditions?
    var activityScores: [ActivityScore] = []
    var sunrise: Date?
    var sunset: Date?
    var portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current

    @State private var showExportMenu = false
    @State private var showCalendarAlert = false
    @State private var calendarMessage = ""
    @State private var isExporting = false
    @State private var showPremiumPaywall = false

    var body: some View {
        Menu {
            // Partager texte
            Button {
                HapticManager.shared.impact(.light)
                ShareService.shared.shareTideText(portName: portName, tideData: tideData, portTimeZone: portTimeZone)
            } label: {
                Label("Partager en texte", systemImage: "text.bubble")
            }

            // Partager SMS court
            Button {
                HapticManager.shared.impact(.light)
                let text = ShareService.shared.generateShortText(portName: portName, tideData: tideData, portTimeZone: portTimeZone)
                ShareService.shared.share(items: [text])
            } label: {
                Label("Message court", systemImage: "message")
            }

            Divider()

            // Carte de marée (Premium)
            Button {
                HapticManager.shared.impact(.light)
                if PremiumManager.shared.canShareCard {
                    shareCard()
                } else {
                    showPremiumPaywall = true
                }
            } label: {
                Label(
                    PremiumManager.shared.canShareCard ? "Carte de marée" : "Carte de marée ⭐️",
                    systemImage: "photo.on.rectangle"
                )
            }

            // Export PDF (Premium)
            Button {
                HapticManager.shared.impact(.light)
                if PremiumManager.shared.canExportPDF {
                    ShareService.shared.shareTidePDF(portName: portName, tideData: tideData, portTimeZone: portTimeZone)
                } else {
                    showPremiumPaywall = true
                }
            } label: {
                Label(
                    PremiumManager.shared.canExportPDF ? "Exporter en PDF" : "Exporter en PDF ⭐️",
                    systemImage: "doc.fill"
                )
            }

            Divider()

            // Export calendrier (aujourd'hui)
            Button {
                HapticManager.shared.impact(.light)
                exportToCalendar(allDays: false)
            } label: {
                Label("Ajouter au calendrier (aujourd'hui)", systemImage: "calendar.badge.plus")
            }

            // Export calendrier (tous les jours)
            Button {
                HapticManager.shared.impact(.light)
                exportToCalendar(allDays: true)
            } label: {
                Label("Ajouter au calendrier (tout)", systemImage: "calendar")
            }
        } label: {
            Group {
                if isExporting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.cyan)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.cyan)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .accessibilityLabel("Partager les marées")
        .alert("Calendrier", isPresented: $showCalendarAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(calendarMessage)
        }
        .sheet(isPresented: $showPremiumPaywall) {
            PremiumPaywallView()
                .presentationDetents([.large])
                .sheetBackground()
        }
    }

    // MARK: - Share Card

    private func shareCard() {
        let calendar = Calendar.current
        let today = Date()
        let startOfDay = calendar.startOfDay(for: today)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay

        // Trouver le coefficient du jour
        let todayCoef = tideData
            .first { $0.date >= startOfDay && $0.date < endOfDay && $0.coefficient != nil }?
            .coefficient

        // Construire les infos météo
        var weatherInfo: TideCardData.WeatherInfo?
        if let w = currentWeather {
            let windSpeed = w.wind.speed.converted(to: .kilometersPerHour).value
            let windDeg = w.wind.direction.converted(to: .degrees).value
            let windDir = Self.windDirectionName(from: windDeg)
            let symbol = w.symbolName
            weatherInfo = TideCardData.WeatherInfo(
                temp: w.temperature.converted(to: .celsius).value,
                windSpeed: windSpeed,
                windDir: windDir,
                symbol: symbol
            )
        }

        // Construire les infos marine
        var marineInfo: TideCardData.MarineInfo?
        if let m = marineConditions {
            marineInfo = TideCardData.MarineInfo(
                waveHeight: m.waveHeight,
                wavePeriod: m.wavePeriod
            )
        }

        let cardData = TideCardData(
            portName: portName,
            date: today,
            tideData: tideData,
            currentHeight: tideState?.currentHeight ?? 0,
            trend: tideState?.trend ?? .rising,
            coefficient: todayCoef,
            weather: weatherInfo,
            marine: marineInfo,
            activityScores: activityScores,
            sunrise: sunrise,
            sunset: sunset,
            portTimeZone: portTimeZone
        )

        TideCardExportService.shareCard(from: cardData)
    }

    // MARK: - Calendar Export

    private func exportToCalendar(allDays: Bool) {
        isExporting = true

        Task {
            let result: Result<Int, CalendarExportService.CalendarExportError>

            if allDays {
                result = await CalendarExportService.shared.exportAllTides(
                    tideData: tideData,
                    portName: portName
                )
            } else {
                result = await CalendarExportService.shared.exportTides(
                    tideData: tideData,
                    portName: portName,
                    date: Date(),
                    portTimeZone: portTimeZone
                )
            }

            await MainActor.run {
                isExporting = false
                switch result {
                case .success(let count):
                    HapticManager.shared.notification(.success)
                    calendarMessage = "\(count) marée\(count > 1 ? "s" : "") ajoutée\(count > 1 ? "s" : "") au calendrier."
                case .failure(let error):
                    HapticManager.shared.notification(.error)
                    calendarMessage = error.localizedDescription
                }
                showCalendarAlert = true
            }
        }
    }

    // MARK: - Helpers

    private static func windDirectionName(from degrees: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let index = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return dirs[min(max(index, 0), dirs.count - 1)]
    }
}

// MARK: - Compact Export Button (for toolbars)
struct CompactExportButton: View {
    let portName: String
    let tideData: [TideData]

    var body: some View {
        ExportButton(portName: portName, tideData: tideData)
    }
}
