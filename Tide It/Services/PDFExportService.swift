//
//  PDFExportService.swift
//  Tide It
//
//  Export des données de marées au format PDF
//

import UIKit
import PDFKit

class PDFExportService {
    static let shared = PDFExportService()

    /// Génère un PDF des données de marées pour un port donné
    func generateTidePDF(
        portName: String,
        tideData: [TideData],
        statistics: TideCalculator.TideStatistics?,
        portTimeZone: TimeZone = TimeZone(identifier: "Europe/Paris") ?? .current
    ) -> Data? {
        let pageWidth: CGFloat = 595.0   // A4
        let pageHeight: CGFloat = 842.0
        let margin: CGFloat = 40.0
        let contentWidth = pageWidth - 2 * margin

        let pdfMetaData = [
            kCGPDFContextCreator: "Tide It",
            kCGPDFContextAuthor: "Tide It App",
            kCGPDFContextTitle: "Marées - \(portName)"
        ]

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]

        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let data = renderer.pdfData { context in
            context.beginPage()

            var yOffset: CGFloat = margin

            // Title
            yOffset = drawTitle(portName: portName, at: yOffset, width: contentWidth, margin: margin)

            // Date
            yOffset = drawDate(at: yOffset, margin: margin)

            // Statistics
            if let stats = statistics {
                yOffset = drawStatistics(stats, at: yOffset, width: contentWidth, margin: margin)
            }

            // Table header
            yOffset = drawTableHeader(at: yOffset, width: contentWidth, margin: margin)

            // Group by day
            let calendar = Calendar.inTimeZone(portTimeZone)
            let grouped = Dictionary(grouping: tideData.sorted { $0.date < $1.date }) { tide in
                calendar.startOfDay(for: tide.date)
            }

            let sortedDays = grouped.keys.sorted()

            for day in sortedDays {
                guard let dayTides = grouped[day] else { continue }

                // Check if we need a new page
                if yOffset > pageHeight - 120 {
                    context.beginPage()
                    yOffset = margin
                    yOffset = drawTableHeader(at: yOffset, width: contentWidth, margin: margin)
                }

                // Day header
                yOffset = drawDayHeader(date: day, at: yOffset, width: contentWidth, margin: margin, timeZone: portTimeZone)

                // Tides for this day
                for tide in dayTides {
                    if yOffset > pageHeight - 60 {
                        context.beginPage()
                        yOffset = margin
                        yOffset = drawTableHeader(at: yOffset, width: contentWidth, margin: margin)
                    }

                    yOffset = drawTideRow(tide: tide, at: yOffset, width: contentWidth, margin: margin, timeZone: portTimeZone)
                }
            }

            // Footer
            drawFooter(pageRect: pageRect, margin: margin)
        }

        return data
    }

    // MARK: - Drawing Helpers

    private func drawTitle(portName: String, at y: CGFloat, width: CGFloat, margin: CGFloat) -> CGFloat {
        let titleFont = UIFont.systemFont(ofSize: 24, weight: .bold)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.black
        ]

        let title = "Marées - \(portName)"
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(at: CGPoint(x: margin, y: y), withAttributes: titleAttributes)

        return y + titleSize.height + 8
    }

    private func drawDate(at y: CGFloat, margin: CGFloat) -> CGFloat {
        let dateFont = UIFont.systemFont(ofSize: 12, weight: .regular)
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: UIColor.darkGray
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .long

        let dateString = "Généré le \(formatter.string(from: Date()))"
        dateString.draw(at: CGPoint(x: margin, y: y), withAttributes: dateAttributes)

        return y + 24
    }

    private func drawStatistics(_ stats: TideCalculator.TideStatistics, at y: CGFloat, width: CGFloat, margin: CGFloat) -> CGFloat {
        var offset = y + 8

        let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let valueFont = UIFont.systemFont(ofSize: 12, weight: .regular)

        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: UIColor.black]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: UIColor.darkGray]

        "Statistiques".draw(at: CGPoint(x: margin, y: offset), withAttributes: headerAttrs)
        offset += 20

        // Unité de l'utilisateur (m/ft) via le groupe d'app — le PDF était toujours en mètres.
        let statsTexts = [
            "PM moyenne : \(SharedUnitFormatter.height(stats.averageHighTide, decimals: 1))",
            "BM moyenne : \(SharedUnitFormatter.height(stats.averageLowTide, decimals: 1))",
            "Marnage moyen : \(SharedUnitFormatter.height(stats.tidalRange, decimals: 1))"
        ]

        for text in statsTexts {
            text.draw(at: CGPoint(x: margin + 10, y: offset), withAttributes: valueAttrs)
            offset += 16
        }

        if let avgCoef = stats.averageCoefficient {
            "Coefficient moyen : \(Int(avgCoef))".draw(at: CGPoint(x: margin + 10, y: offset), withAttributes: valueAttrs)
            offset += 16
        }

        // Separator line
        offset += 8
        let context = UIGraphicsGetCurrentContext()
        context?.setStrokeColor(UIColor.lightGray.cgColor)
        context?.setLineWidth(0.5)
        context?.move(to: CGPoint(x: margin, y: offset))
        context?.addLine(to: CGPoint(x: margin + width, y: offset))
        context?.strokePath()

        return offset + 12
    }

    private func drawTableHeader(at y: CGFloat, width: CGFloat, margin: CGFloat) -> CGFloat {
        let headerFont = UIFont.systemFont(ofSize: 10, weight: .bold)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: UIColor.darkGray]

        let columns: [(String, CGFloat)] = [
            ("Type", margin),
            ("Heure", margin + 60),
            ("Hauteur", margin + 140),
            ("Coefficient", margin + 220),
        ]

        // Background
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor(white: 0.95, alpha: 1.0).cgColor)
        context?.fill(CGRect(x: margin, y: y, width: width, height: 20))

        for (text, x) in columns {
            text.draw(at: CGPoint(x: x, y: y + 4), withAttributes: headerAttrs)
        }

        return y + 24
    }

    private func drawDayHeader(date: Date, at y: CGFloat, width: CGFloat, margin: CGFloat, timeZone: TimeZone) -> CGFloat {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"

        let dayFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let dayAttrs: [NSAttributedString.Key: Any] = [.font: dayFont, .foregroundColor: UIColor.black]

        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor(white: 0.92, alpha: 1.0).cgColor)
        context?.fill(CGRect(x: margin, y: y, width: width, height: 18))

        formatter.string(from: date).capitalized.draw(at: CGPoint(x: margin + 4, y: y + 2), withAttributes: dayAttrs)

        return y + 22
    }

    private func drawTideRow(tide: TideData, at y: CGFloat, width: CGFloat, margin: CGFloat, timeZone: TimeZone) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"

        let typeText = tide.isHighTide ? "PM ▲" : "BM ▼"
        let timeText = timeFormatter.string(from: tide.date)
        let heightText = SharedUnitFormatter.height(tide.height, decimals: 2)
        let coefText = tide.coefficient.map { "\($0)" } ?? "—"

        typeText.draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        timeText.draw(at: CGPoint(x: margin + 60, y: y), withAttributes: attrs)
        heightText.draw(at: CGPoint(x: margin + 140, y: y), withAttributes: attrs)
        coefText.draw(at: CGPoint(x: margin + 220, y: y), withAttributes: attrs)

        // Light separator
        let context = UIGraphicsGetCurrentContext()
        context?.setStrokeColor(UIColor(white: 0.9, alpha: 1.0).cgColor)
        context?.setLineWidth(0.3)
        context?.move(to: CGPoint(x: margin, y: y + 16))
        context?.addLine(to: CGPoint(x: margin + width, y: y + 16))
        context?.strokePath()

        return y + 18
    }

    private func drawFooter(pageRect: CGRect, margin: CGFloat) {
        let footerFont = UIFont.systemFont(ofSize: 8, weight: .regular)
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: footerFont,
            .foregroundColor: UIColor.lightGray
        ]

        let footer = "Généré par Tide It"
        let footerSize = footer.size(withAttributes: footerAttrs)
        footer.draw(
            at: CGPoint(
                x: pageRect.width / 2 - footerSize.width / 2,
                y: pageRect.height - margin + 10
            ),
            withAttributes: footerAttrs
        )
    }
}
