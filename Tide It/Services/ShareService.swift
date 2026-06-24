//
//  ShareService.swift
//  Tide It
//
//  Service de partage des données de marées (texte, PDF, image)
//

import UIKit
import SwiftUI
import os.log

class ShareService {
    static let shared = ShareService()

    /// Génère un texte de partage des marées du jour
    func generateShareText(portName: String, tideData: [TideData], date: Date = Date(),
                           portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current) -> String {
        let calendar = Calendar.inTimeZone(portTimeZone)
        let todayTides = tideData.filter { calendar.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date < $1.date }

        guard !todayTides.isEmpty else {
            return "Tide It - \(portName)\nAucune donnée de marée disponible."
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.timeZone = portTimeZone
        dateFormatter.dateFormat = "EEEE d MMMM yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.timeZone = portTimeZone
        timeFormatter.dateFormat = "HH:mm"

        var text = "🌊 Marées - \(portName)\n"
        text += "📅 \(dateFormatter.string(from: date).capitalized)\n\n"

        // Unité de l'utilisateur (m/ft) — le texte partagé était toujours en mètres.
        let sys = MeasureSystem(rawValue: UserDefaults.standard.string(forKey: "measureSystem") ?? "") ?? .metric
        for tide in todayTides {
            let type = tide.isHighTide ? "▲ PM" : "▼ BM"
            let time = timeFormatter.string(from: tide.date)
            let height = UnitFormatter.height(tide.height, system: sys, decimals: 2)
            let coef = tide.coefficient.map { " (coef \($0))" } ?? ""
            text += "\(type) \(time) — \(height)\(coef)\n"
        }

        text += "\nPartagé via Tide It"
        return text
    }

    /// Génère un texte court pour les marées (ex: pour iMessage)
    func generateShortText(portName: String, tideData: [TideData],
                           portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current) -> String {
        let calendar = Calendar.inTimeZone(portTimeZone)
        let todayTides = tideData.filter { calendar.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }

        guard !todayTides.isEmpty else {
            return "\(portName) - Pas de données"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.timeZone = portTimeZone
        timeFormatter.dateFormat = "HH:mm"

        let parts = todayTides.map { tide -> String in
            let type = tide.isHighTide ? "↑" : "↓"
            let time = timeFormatter.string(from: tide.date)
            return "\(type)\(time) \(String(format: "%.1fm", tide.height))"
        }

        return "🌊 \(portName): \(parts.joined(separator: " | "))"
    }

    /// Partage via UIActivityViewController
    func share(items: [Any], from viewController: UIViewController? = nil) {
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        // Exclure certaines activités non pertinentes
        activityVC.excludedActivityTypes = [
            .assignToContact,
            .addToReadingList,
            .openInIBooks
        ]

        if let vc = viewController ?? topViewController() {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = vc.view
                popover.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            vc.present(activityVC, animated: true)
        }
    }

    /// Partage du texte des marées
    func shareTideText(portName: String, tideData: [TideData],
                       portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current) {
        let text = generateShareText(portName: portName, tideData: tideData, portTimeZone: portTimeZone)
        share(items: [text])
    }

    /// Partage du PDF des marées
    func shareTidePDF(portName: String, tideData: [TideData],
                      portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current) {
        let stats = TideCalculator.statistics(for: tideData)
        guard let pdfData = PDFExportService.shared.generateTidePDF(
            portName: portName,
            tideData: tideData,
            statistics: stats,
            portTimeZone: portTimeZone
        ) else { return }

        // Sauvegarder temporairement
        let fileName = "marees_\(portName.replacingOccurrences(of: " ", with: "_")).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try pdfData.write(to: tempURL)
            share(items: [tempURL])
        } catch {
            appLogger.error("Erreur sauvegarde PDF temporaire: \(error)")
        }
    }

    // MARK: - Helpers
    private func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else {
            return nil
        }

        while let presented = top.presentedViewController {
            top = presented
        }

        return top
    }
}
