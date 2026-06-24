//
//  TideCardExportService.swift
//  Tide It
//
//  Génère et partage une image de carte de marée (1080×1920 px Stories)
//

import SwiftUI
import os.log

@MainActor
enum TideCardExportService {

    /// Génère une UIImage 1080×1920 à partir des données de marée
    static func generateImage(from data: TideCardData) -> UIImage? {
        let cardView = TideCardView(data: data)
            .environmentObject(ThemeManager.shared)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0 // 360×640 × 3 = 1080×1920
        renderer.proposedSize = .init(width: 360, height: 640)

        guard let image = renderer.uiImage else {
            appLogger.error("[TideCard] Échec de la génération d'image")
            return nil
        }

        appLogger.info("[TideCard] Image générée : \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)) px")
        return image
    }

    /// Génère l'image et ouvre la share sheet
    static func shareCard(from data: TideCardData) {
        guard let image = generateImage(from: data) else { return }
        ShareService.shared.share(items: [image])
    }
}
