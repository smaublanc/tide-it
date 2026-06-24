//
//  FontScaling.swift
//  Tide It
//
//  Helpers pour faire cohabiter des tailles de police FIXES (design system DS)
//  avec le support Dynamic Type d'iOS.
//
//  `UIFontMetrics` permet de scaler une taille donnée relativement à un
//  text style système. On obtient ainsi : préservation du design exact à la
//  taille par défaut (.large) + scaling contrôlé pour les utilisateurs ayant
//  une préférence Dynamic Type différente.
//
//  Usage :
//      Text("Bonjour").font(.scaled(size: DS.fontBody, weight: .medium))
//
//  Le design système de Tide It reste piloté par les constantes DS ; cette
//  extension ajoute juste le support Dynamic Type sans tout réécrire.
//

import SwiftUI
import UIKit

extension Font {

    /// Crée une Font système dont la taille en points est scalée par
    /// Dynamic Type, relativement à un text style système.
    ///
    /// - Parameters:
    ///   - size: Taille de base (au setting Dynamic Type `.large`).
    ///   - weight: Poids de la police.
    ///   - design: Design (par défaut, `.default`).
    ///   - textStyle: Text style relatif pour le scaling (par défaut `.body`).
    /// - Returns: Une `Font` qui respecte Dynamic Type.
    static func scaled(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: UIFont.TextStyle = .body
    ) -> Font {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let scaled = metrics.scaledValue(for: size)
        return .system(size: scaled, weight: weight, design: design)
    }
}

// MARK: - Raccourcis DS

extension Font {
    /// Police de corps scalable (DS.fontBody = 15pt).
    static func dsBody(weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .scaled(size: DS.fontBody, weight: weight, design: design, relativeTo: .body)
    }

    /// Police de titre scalable (DS.fontHeadline = 16pt).
    static func dsHeadline(weight: Font.Weight = .semibold, design: Font.Design = .default) -> Font {
        .scaled(size: DS.fontHeadline, weight: weight, design: design, relativeTo: .headline)
    }

    /// Police secondaire scalable (DS.fontSubheadline = 14pt).
    static func dsSubheadline(weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .scaled(size: DS.fontSubheadline, weight: weight, design: design, relativeTo: .subheadline)
    }

    /// Police footnote scalable (DS.fontFootnote = 13pt).
    static func dsFootnote(weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .scaled(size: DS.fontFootnote, weight: weight, design: design, relativeTo: .footnote)
    }

    /// Police caption scalable (DS.fontCaption = 11pt).
    static func dsCaption(weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .scaled(size: DS.fontCaption, weight: weight, design: design, relativeTo: .caption2)
    }
}

// MARK: - ViewModifier helper

extension View {
    /// Raccourci pour appliquer `.font(.scaled(...))` avec `.minimumScaleFactor`.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: UIFont.TextStyle = .body,
        minScale: CGFloat = 0.8
    ) -> some View {
        self
            .font(.scaled(size: size, weight: weight, design: design, relativeTo: textStyle))
            .minimumScaleFactor(minScale)
            .allowsTightening(true)
    }
}
